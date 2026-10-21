#!/usr/bin/env bash
# build-unbound.sh - rebuild Debian's current unbound packages for Ubuntu 24.04.
#
# Debian's unbound maintainers package every upstream release, usually on the
# day it comes out. This script downloads their source package (verified
# against Debian's archive signing keys), rebuilds it against Ubuntu 24.04's
# libraries and bundles the resulting .debs so you can copy them to a server.
#
# Three ways to run it:
#   ./build-unbound.sh --docker               any machine with Docker or Podman
#   ./build-unbound.sh --docker --arch arm64  build for an ARM server (emulated, slow)
#   sudo ./build-unbound.sh                   directly on an Ubuntu 24.04 machine
#                                             (installs build dependencies on it)
#
# Results go to ./out (or OUT_DIR):
#   unbound-noble-<arch>.tar.gz          the .debs + SHA256SUMS + BUILDINFO
#   unbound-noble-<arch>.tar.gz.sha256   checksum of that bundle
#   debs/                                the same .debs, loose
#
# Settings (environment variables):
#   DEBIAN_SUITE  Debian suite to take the packaging from (default: unstable).
#                 For Debian stable's security updates instead, use
#                 DEBIAN_SUITE=trixie-security
#                 DEBIAN_MIRROR=https://deb.debian.org/debian-security
#   DEB_VERSION   exact Debian version to build (default: newest in DEBIAN_SUITE)
#   BUILD_REV     rebuild counter in the version suffix (default: 1),
#                 e.g. 1.26.1-1 becomes 1.26.1-1~ubuntu24.04.1
#   NOCHECK=1     skip upstream's test suite (faster; useful for emulated builds)
#   OUT_DIR       output directory (default: ./out)
#   IMAGE         container image for --docker (default: ubuntu:24.04)
#   CONTAINER_ENGINE  docker or podman (default: whichever is installed)

set -euo pipefail

DEBIAN_SUITE=${DEBIAN_SUITE:-unstable}
DEBIAN_MIRROR=${DEBIAN_MIRROR:-https://deb.debian.org/debian}
DEB_VERSION=${DEB_VERSION:-}
BUILD_REV=${BUILD_REV:-1}
NOCHECK=${NOCHECK:-0}
OUT_DIR=${OUT_DIR:-$PWD/out}
IMAGE=${IMAGE:-ubuntu:24.04}
BUILD_MAINTAINER=${BUILD_MAINTAINER:-unbound rebuild <unbound-rebuild@localhost>}

# Debian rotates its archive signing key once per release. The keyring that
# ships with Ubuntu 24.04 predates Debian 13, so the newer keys are fetched
# from ftp-master.debian.org and checked against these fingerprints (from
# https://ftp-master.debian.org/keys.html). Add more as "file:FINGERPRINT"
# in EXTRA_DEBIAN_KEYS when Debian introduces a new key.
DEBIAN_KEYS=(
    "archive-key-12.asc:B8B80B5B623EAB6AD8775C45B7C5D7D6350947F8"
    "archive-key-13.asc:04B54C3CDCA79751B16BC6B5225629DF75B188BD"
    "archive-key-12-security.asc:05AB90340C0C5E797F44A8C8254CF3B5AEC0A8F0"
    "archive-key-13-security.asc:5E04A1E3223A19A20706E20F9904613D4CCE68C6"
)
read -r -a extra_keys <<< "${EXTRA_DEBIAN_KEYS:-}"
DEBIAN_KEYS+=(${extra_keys[@]+"${extra_keys[@]}"})

log()  { printf '==> %s\n' "$*" >&2; }
warn() { printf 'warning: %s\n' "$*" >&2; }
die()  { printf 'error: %s\n' "$*" >&2; exit 1; }

usage() {
    sed -n '2,/^$/{s/^# \{0,1\}//;p;}' "$0" >&2
    cat >&2 <<'EOF'
Options:
  --docker          build inside a fresh container (needs Docker or Podman)
  --arch ARCH       with --docker: target architecture, e.g. arm64
  --dsc FILE        build this local source package instead of Debian's
  --out DIR         output directory (same as OUT_DIR)
  --print-version   only print the Debian version that would be built
  -h, --help        show this help
EOF
}

mode=build
use_container=0
target_arch=
dsc_file=

while [ $# -gt 0 ]; do
    case $1 in
        --docker|--podman|--container) use_container=1 ;;
        --arch)           target_arch=${2:?--arch needs a value}; shift ;;
        --dsc)            dsc_file=${2:?--dsc needs a file}; shift ;;
        --out)            OUT_DIR=${2:?--out needs a directory}; shift ;;
        --print-version)  mode=print-version ;;
        -h|--help)        usage; exit 0 ;;
        *)                usage; die "unknown option: $1" ;;
    esac
    shift
done

# --------------------------------------------------------------------------
# Container wrapper: re-run this script inside a clean Ubuntu 24.04 image.
# --------------------------------------------------------------------------
run_in_container() {
    local engine=${CONTAINER_ENGINE:-}
    if [ -z "$engine" ]; then
        if command -v docker >/dev/null 2>&1; then engine=docker
        elif command -v podman >/dev/null 2>&1; then engine=podman
        else die "neither docker nor podman found"; fi
    fi

    local script_dir out_abs
    script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
    mkdir -p "$OUT_DIR"
    out_abs=$(cd "$OUT_DIR" && pwd)

    local -a run_args=(run --rm -i
        -e DEBIAN_SUITE -e DEBIAN_MIRROR -e DEB_VERSION -e BUILD_REV -e NOCHECK
        -e BUILD_MAINTAINER -e EXTRA_DEBIAN_KEYS -e DEB_BUILD_OPTIONS
        -e OUT_DIR=/out -e "HOST_UID=$(id -u)" -e "HOST_GID=$(id -g)"
        -v "$script_dir:/src:ro" -v "$out_abs:/out")
    local -a inner_args=()

    if [ -n "$target_arch" ]; then
        run_args+=(--platform "linux/$target_arch")
    fi
    if [ "$mode" = print-version ]; then
        inner_args+=(--print-version)
    fi
    if [ -n "$dsc_file" ]; then
        local dsc_dir
        dsc_dir=$(cd "$(dirname "$dsc_file")" && pwd)
        run_args+=(-v "$dsc_dir:/dsc:ro")
        inner_args+=(--dsc "/dsc/$(basename "$dsc_file")")
    fi

    log "running in $engine ($IMAGE${target_arch:+, $target_arch})"
    exec "$engine" "${run_args[@]}" "$IMAGE" bash /src/build-unbound.sh \
        ${inner_args[@]+"${inner_args[@]}"}
}

if [ "$use_container" = 1 ]; then
    run_in_container
fi

# --------------------------------------------------------------------------
# Native mode: everything below runs on Ubuntu 24.04 as root.
# --------------------------------------------------------------------------
[ "$(id -u)" -eq 0 ] || die "run as root, or use --docker"
[ -z "$target_arch" ] || die "--arch only works together with --docker"
[ -r /etc/os-release ] || die "cannot read /etc/os-release"
# shellcheck disable=SC1091
. /etc/os-release
[ "${ID:-}" = ubuntu ] || die "this must run on Ubuntu (found ${ID:-unknown}); use --docker"
[ "${VERSION_ID:-}" = 24.04 ] || warn "built for Ubuntu 24.04; this is ${VERSION_ID:-unknown} (untested)"

export DEBIAN_FRONTEND=noninteractive
mkdir -p "$OUT_DIR"
OUT_DIR=$(cd "$OUT_DIR" && pwd)
WORK=$(mktemp -d /tmp/unbound-build.XXXXXX)
trap 'rm -rf "$WORK"' EXIT

apt_install() {
    apt-get install -y --no-install-recommends "$@" >&2
}

# Build one keyring from Ubuntu's copy of Debian's keys plus the pinned newer
# keys fetched from ftp-master.debian.org.
build_keyring() {
    local keyring=$1 gnupg="$WORK/gnupg" entry file fpr got
    mkdir -p "$gnupg" && chmod 700 "$gnupg"
    : > "$keyring"
    if [ -s /usr/share/keyrings/debian-archive-keyring.gpg ]; then
        cat /usr/share/keyrings/debian-archive-keyring.gpg >> "$keyring"
    fi
    for entry in "${DEBIAN_KEYS[@]}"; do
        [ -n "$entry" ] || continue
        file=${entry%%:*}
        fpr=${entry##*:}
        if ! curl -fsSL --retry 3 -o "$WORK/$file" "https://ftp-master.debian.org/keys/$file"; then
            warn "could not download $file; relying on Ubuntu's copy of the Debian keys"
            continue
        fi
        got=$(GNUPGHOME=$gnupg gpg --batch --quiet --with-colons --show-keys "$WORK/$file" 2>/dev/null \
              | awk -F: '$1 == "fpr" { print $10; exit }')
        [ "$got" = "$fpr" ] || die "$file has fingerprint '${got:-none}', expected $fpr"
        GNUPGHOME=$gnupg gpg --batch --yes --dearmor -o "$WORK/$file.gpg" "$WORK/$file"
        cat "$WORK/$file.gpg" >> "$keyring"
    done
    [ -s "$keyring" ] || die "no Debian archive keys available"
}

# A private apt configuration that only knows Debian's source index, so the
# system's own apt setup is never touched.
APTDIR="$WORK/apt"
APT_DEBIAN=()
setup_debian_apt() {
    mkdir -p "$APTDIR/lists/partial" "$APTDIR/cache/archives/partial" "$APTDIR/sources.list.d"
    : > "$APTDIR/sources.list"
    build_keyring "$APTDIR/debian-archive.gpg"
    cat > "$APTDIR/sources.list.d/debian.sources" <<EOF
Types: deb-src
URIs: $DEBIAN_MIRROR
Suites: $DEBIAN_SUITE
Components: main
Signed-By: $APTDIR/debian-archive.gpg
EOF
    APT_DEBIAN=(
        -o "Dir::Etc::SourceList=$APTDIR/sources.list"
        -o "Dir::Etc::SourceParts=$APTDIR/sources.list.d"
        -o "Dir::State::Lists=$APTDIR/lists"
        -o "Dir::Cache=$APTDIR/cache"
        -o "Dir::Cache::pkgcache="
        -o "Dir::Cache::srcpkgcache="
        -o "APT::Sandbox::User=root"
        -o "Acquire::Languages=none"
    )
    log "reading Debian $DEBIAN_SUITE source index (signature-checked)"
    apt-get "${APT_DEBIAN[@]}" update >&2
}

newest_debian_version() {
    local best='' v
    while read -r v; do
        if [ -z "$best" ] || dpkg --compare-versions "$v" gt "$best"; then
            best=$v
        fi
    done < <(apt-cache "${APT_DEBIAN[@]}" showsrc --only-source unbound 2>/dev/null \
             | awk '$1 == "Version:" { print $2 }')
    [ -n "$best" ] || die "no unbound source package found in Debian $DEBIAN_SUITE"
    printf '%s\n' "$best"
}

log "installing tools"
apt-get update -qq >&2
if [ "$mode" = print-version ]; then
    apt_install ca-certificates curl gnupg debian-archive-keyring
else
    apt_install ca-certificates curl gnupg dpkg-dev debian-archive-keyring
fi

if [ -z "$dsc_file" ]; then
    setup_debian_apt
    [ -n "$DEB_VERSION" ] || DEB_VERSION=$(newest_debian_version)
fi

if [ "$mode" = print-version ]; then
    [ -z "$dsc_file" ] || die "--print-version and --dsc do not go together"
    printf '%s\n' "$DEB_VERSION"
    exit 0
fi

# --------------------------------------------------------------------------
# Fetch and unpack the source package.
# --------------------------------------------------------------------------
mkdir -p "$WORK/src"
if [ -n "$dsc_file" ]; then
    [ -r "$dsc_file" ] || die "cannot read $dsc_file"
    warn "building local source package $dsc_file (its signature is not checked)"
    dsc_dir=$(dirname "$dsc_file")
    cp "$dsc_file" "$WORK/src/"
    while read -r f; do
        cp "$dsc_dir/$f" "$WORK/src/"
    done < <(awk '/^Checksums-Sha256:/ { s = 1; next } /^[^ ]/ { s = 0 } s && NF == 3 { print $3 }' "$dsc_file")
    DSC="$WORK/src/$(basename "$dsc_file")"
    DEB_VERSION=$(awk '$1 == "Version:" { print $2; exit }' "$DSC")
    [ -n "$DEB_VERSION" ] || die "no Version field in $dsc_file"
else
    log "downloading Debian source package unbound $DEB_VERSION"
    (cd "$WORK/src" && apt-get "${APT_DEBIAN[@]}" source --download-only "unbound=$DEB_VERSION" >&2)
    DSC="$WORK/src/unbound_${DEB_VERSION#*:}.dsc"
fi
[ -r "$DSC" ] || die "source package download failed"

SRCDIR="$WORK/src/unbound"
# dpkg-source verifies every file against the checksums in the .dsc.
dpkg-source -x "$DSC" "$SRCDIR" >&2

PKG_VERSION="${DEB_VERSION}~ubuntu${VERSION_ID}.${BUILD_REV}"
UPSTREAM_VERSION=${DEB_VERSION#*:}
UPSTREAM_VERSION=${UPSTREAM_VERSION%-*}

{
    printf 'unbound (%s) %s; urgency=medium\n\n' "$PKG_VERSION" "$VERSION_CODENAME"
    printf '  * Automated rebuild of Debian unbound %s for Ubuntu %s.\n\n' "$DEB_VERSION" "$VERSION_ID"
    printf ' -- %s  %s\n\n' "$BUILD_MAINTAINER" "$(date -R)"
    cat "$SRCDIR/debian/changelog"
} > "$SRCDIR/debian/changelog.new"
mv "$SRCDIR/debian/changelog.new" "$SRCDIR/debian/changelog"

# --------------------------------------------------------------------------
# Build.
# --------------------------------------------------------------------------
log "installing build dependencies from the Ubuntu $VERSION_ID archive"
apt_install build-essential
apt-get build-dep -y --no-install-recommends "$SRCDIR" >&2

build_opts="parallel=$(nproc) ${DEB_BUILD_OPTIONS:-}"
build_profiles=
if [ "$NOCHECK" = 1 ]; then
    build_opts="$build_opts nocheck"
    build_profiles=nocheck
fi

log "building unbound $PKG_VERSION (upstream $UPSTREAM_VERSION)"
(cd "$SRCDIR" && DEB_BUILD_OPTIONS=$build_opts DEB_BUILD_PROFILES=$build_profiles \
    dpkg-buildpackage -b -uc -us >&2)

# --------------------------------------------------------------------------
# Bundle the results.
# --------------------------------------------------------------------------
ARCH=$(dpkg --print-architecture)
NAME="unbound-${VERSION_CODENAME}-${ARCH}"
STAGE="$WORK/$NAME"
mkdir -p "$STAGE" "$OUT_DIR/debs"

shopt -s nullglob
debs=("$WORK"/src/*.deb)
shopt -u nullglob
[ ${#debs[@]} -gt 0 ] || die "the build produced no .deb files"
cp "${debs[@]}" "$STAGE/"

if [ -n "$dsc_file" ]; then
    source_origin="local file $(basename "$dsc_file")"
else
    source_origin="Debian $DEBIAN_SUITE"
fi

cat > "$STAGE/BUILDINFO" <<EOF
package_version=$PKG_VERSION
upstream_version=$UPSTREAM_VERSION
debian_version=$DEB_VERSION
source=$source_origin
built_for=Ubuntu $VERSION_ID ($VERSION_CODENAME) $ARCH
built_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
dsc_sha256=$(sha256sum "$DSC" | cut -d' ' -f1)
EOF

(
    cd "$STAGE"
    sha256sum -- *.deb > SHA256SUMS
    tar -czf "$OUT_DIR/$NAME.tar.gz" SHA256SUMS BUILDINFO -- *.deb
)
(cd "$OUT_DIR" && sha256sum "$NAME.tar.gz" > "$NAME.tar.gz.sha256")

rm -f "$OUT_DIR"/debs/*.deb
cp "$STAGE"/*.deb "$OUT_DIR/debs/"

if [ -n "${HOST_UID:-}" ] && [ -n "${HOST_GID:-}" ]; then
    chown -R "$HOST_UID:$HOST_GID" "$OUT_DIR"
fi

log "done: unbound $PKG_VERSION"
log "bundle: $OUT_DIR/$NAME.tar.gz"
for deb in "$OUT_DIR"/debs/*.deb; do
    printf '    %s\n' "$(basename "$deb")" >&2
done
