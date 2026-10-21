#!/usr/bin/env bash
# update-unbound.sh - install a newer unbound build on this Ubuntu server.
#
# Installs a bundle made by build-unbound.sh (or the GitHub workflow) and
# protects the running resolver while doing it:
#   * verifies the bundle's checksums
#   * tests your current config with the NEW unbound-checkconf first
#   * keeps the current packages on disk so it can roll back even if DNS
#     on this machine is broken
#   * never overwrites config files you have edited
#   * after upgrading, checks the service and a real DNS lookup, and rolls
#     back automatically if either fails
#
# Usage:
#   sudo ./update-unbound.sh --repo OWNER/REPO       newest GitHub release
#   sudo ./update-unbound.sh --file unbound-noble-amd64.tar.gz
#   ./update-unbound.sh --repo OWNER/REPO --check    only compare versions
#   sudo ./update-unbound.sh --repo OWNER/REPO --install-timer
#                                                    update automatically every day
#
# Settings may be stored in /etc/default/unbound-update:
#   REPO=owner/repo          GitHub repository that publishes the bundles
#   CHECK_SERVER=127.0.0.1   address unbound answers on
#   CHECK_PORT=53            port unbound answers on (5335 in many Pi-hole setups)
#   CHECK_NAME=nlnetlabs.nl  name looked up by the health check
#   KEEP_VERSIONS=3          how many versions to keep for rollback
#   GH_TOKEN=...             only for private repositories (needs the gh CLI);
#                            chmod 600 the file if you put a token in it

set -euo pipefail

CONFIG_FILE=/etc/default/unbound-update
CACHE_DIR=/var/cache/unbound-update
BACKUP_DIR=/var/backups
INSTALL_PATH=/usr/local/sbin/update-unbound.sh
LOCK_FILE=/run/unbound-update.lock
KNOWN_PACKAGES=" unbound unbound-anchor unbound-host libunbound8 libunbound-dev python3-unbound "

log()  { printf '==> %s\n' "$*"; }
warn() { printf 'warning: %s\n' "$*" >&2; }
die()  { printf 'error: %s\n' "$*" >&2; exit 1; }

usage() { sed -n '2,/^$/{s/^# \{0,1\}//;p;}' "$0"; }

# shellcheck disable=SC1090
[ -r "$CONFIG_FILE" ] && . "$CONFIG_FILE"
[ -z "${GH_TOKEN:-}" ] || export GH_TOKEN
REPO=${REPO:-}
CHECK_SERVER=${CHECK_SERVER:-127.0.0.1}
CHECK_PORT=${CHECK_PORT:-53}
CHECK_NAME=${CHECK_NAME:-nlnetlabs.nl}
KEEP_VERSIONS=${KEEP_VERSIONS:-3}

bundle_file=
check_only=0
force=0
install_timer=0

while [ $# -gt 0 ]; do
    case $1 in
        --repo)          REPO=${2:?--repo needs OWNER/REPO}; shift ;;
        --file)          bundle_file=${2:?--file needs a path}; shift ;;
        --check)         check_only=1 ;;
        --force)         force=1 ;;
        --install-timer) install_timer=1 ;;
        -h|--help)       usage; exit 0 ;;
        *)               usage >&2; die "unknown option: $1" ;;
    esac
    shift
done

command -v dpkg >/dev/null || die "this script is for Debian/Ubuntu systems"
if [ -n "$REPO" ] && ! printf '%s' "$REPO" | grep -Eq '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$'; then
    die "REPO must look like owner/name, got: $REPO"
fi
ARCH=$(dpkg --print-architecture)
# shellcheck disable=SC1091
CODENAME=$(. /etc/os-release && printf '%s' "${VERSION_CODENAME:-}")
[ -n "$CODENAME" ] || die "cannot tell which Ubuntu release this is"
ASSET="unbound-$CODENAME-$ARCH.tar.gz"

# --------------------------------------------------------------------------
# --install-timer: copy this script into place and run it daily.
# --------------------------------------------------------------------------
if [ "$install_timer" = 1 ]; then
    [ "$(id -u)" -eq 0 ] || die "run as root"
    [ -n "$REPO" ] || die "--install-timer needs --repo OWNER/REPO"
    grep -q 'update-unbound.sh - install a newer unbound' "$0" 2>/dev/null \
        || die "save this script to a file and run it from there"
    install -m 0755 "$0" "$INSTALL_PATH"
    if [ -f "$CONFIG_FILE" ] && grep -q '^REPO=' "$CONFIG_FILE"; then
        sed -i "s|^REPO=.*|REPO=$REPO|" "$CONFIG_FILE"
    else
        printf 'REPO=%s\n' "$REPO" >> "$CONFIG_FILE"
    fi
    cat > /etc/systemd/system/unbound-update.service <<EOF
[Unit]
Description=Install newer unbound builds from $REPO
Wants=network-online.target
After=network-online.target

[Service]
Type=oneshot
ExecStart=$INSTALL_PATH
EOF
    cat > /etc/systemd/system/unbound-update.timer <<'EOF'
[Unit]
Description=Check for newer unbound builds once a day

[Timer]
OnCalendar=daily
RandomizedDelaySec=4h
Persistent=true

[Install]
WantedBy=timers.target
EOF
    systemctl daemon-reload
    systemctl enable --now unbound-update.timer
    log "installed $INSTALL_PATH, settings in $CONFIG_FILE"
    log "daily check enabled; logs: journalctl -u unbound-update"
    log "run now: sudo systemctl start unbound-update   (stop: sudo systemctl disable --now unbound-update.timer)"
    exit 0
fi

[ -n "$bundle_file" ] || [ -n "$REPO" ] || die "use --repo OWNER/REPO or --file BUNDLE (or set REPO in $CONFIG_FILE)"
if [ "$check_only" = 0 ]; then
    [ "$(id -u)" -eq 0 ] || die "run as root (or use --check)"
    exec 9> "$LOCK_FILE"
    flock -n 9 || die "another update is already running"
fi

TMP=$(mktemp -d /tmp/unbound-update.XXXXXX)
trap 'rm -rf "$TMP"' EXIT
export DEBIAN_FRONTEND=noninteractive NEEDRESTART_SUSPEND=1

# --------------------------------------------------------------------------
# Get the bundle and verify it.
# --------------------------------------------------------------------------
if [ -n "$bundle_file" ]; then
    [ -r "$bundle_file" ] || die "cannot read $bundle_file"
    cp "$bundle_file" "$TMP/$ASSET"
    if [ -r "$bundle_file.sha256" ]; then
        cp "$bundle_file.sha256" "$TMP/$ASSET.sha256"
    else
        warn "no $(basename "$bundle_file").sha256 next to the bundle; only its contents will be checked"
    fi
elif command -v gh >/dev/null 2>&1 && [ -n "${GH_TOKEN:-}${GITHUB_TOKEN:-}" ]; then
    log "downloading $ASSET from the latest release of $REPO (gh)"
    gh release download --repo "$REPO" --pattern "$ASSET" --pattern "$ASSET.sha256" --dir "$TMP" \
        || die "could not download $ASSET from $REPO"
else
    log "downloading $ASSET from the latest release of $REPO"
    base="https://github.com/$REPO/releases/latest/download"
    for f in "$ASSET" "$ASSET.sha256"; do
        curl -fsSL --retry 3 --connect-timeout 15 -o "$TMP/$f" "$base/$f" \
            || die "could not download $base/$f (wrong repo, private repo without GH_TOKEN, or no $ARCH build in the latest release?)"
    done
fi

if [ -f "$TMP/$ASSET.sha256" ]; then
    expected=$(awk '{ print $1; exit }' "$TMP/$ASSET.sha256")
    actual=$(sha256sum "$TMP/$ASSET" | awk '{ print $1 }')
    if [ -z "$expected" ] || [ "$expected" != "$actual" ]; then
        die "checksum mismatch for $ASSET"
    fi
fi

# Only accept plain file names, so nothing can be written outside $TMP/x.
while read -r member; do
    case $member in
        SHA256SUMS|BUILDINFO) ;;
        */*|.*|*..*) die "unexpected entry in bundle: $member" ;;
        *.deb) ;;
        *) die "unexpected entry in bundle: $member" ;;
    esac
done < <(tar -tzf "$TMP/$ASSET")

mkdir "$TMP/x"
tar -xzf "$TMP/$ASSET" -C "$TMP/x" --no-same-owner --no-same-permissions
[ -f "$TMP/x/SHA256SUMS" ] || die "bundle has no SHA256SUMS"
(cd "$TMP/x" && sha256sum --quiet -c SHA256SUMS) || die "a package in the bundle is corrupt"

declare -A deb_for=()
NEW_VERSION=
for deb in "$TMP"/x/*.deb; do
    [ -e "$deb" ] || die "bundle contains no packages"
    grep -qF "  $(basename "$deb")" "$TMP/x/SHA256SUMS" || die "$(basename "$deb") is not listed in SHA256SUMS"
    pkg=$(dpkg-deb -f "$deb" Package)
    arch=$(dpkg-deb -f "$deb" Architecture)
    ver=$(dpkg-deb -f "$deb" Version)
    case $KNOWN_PACKAGES in
        *" $pkg "*) ;;
        *) warn "ignoring unexpected package $pkg"; continue ;;
    esac
    [ "$arch" = "$ARCH" ] || [ "$arch" = all ] || die "$pkg is built for $arch, this machine is $ARCH"
    deb_for[$pkg]=$deb
    [ "$pkg" = unbound ] && NEW_VERSION=$ver
done
[ -n "$NEW_VERSION" ] || die "bundle does not contain the unbound package"

installed_version() {
    { dpkg-query -W -f='${db:Status-Abbrev} ${Version}\n' "$1" 2>/dev/null || true; } \
        | awk '$1 ~ /^.i/ { print $2 }'
}
CUR_VERSION=$(installed_version unbound)

[ -f "$TMP/x/BUILDINFO" ] && sed 's/^/    /' "$TMP/x/BUILDINFO"
log "installed: ${CUR_VERSION:-none}"
log "available: $NEW_VERSION"

if [ "$check_only" = 1 ]; then
    if [ -z "$CUR_VERSION" ] || dpkg --compare-versions "$NEW_VERSION" gt "$CUR_VERSION"; then
        log "an update is available"
    else
        log "up to date"
    fi
    exit 0
fi

if [ -n "$CUR_VERSION" ] && [ "$force" = 0 ] && dpkg --compare-versions "$NEW_VERSION" le "$CUR_VERSION"; then
    log "up to date, nothing to do"
    exit 0
fi

# Install unbound itself, its library, and our build of anything else from
# the bundle that is already installed here.
selected=()
for pkg in "${!deb_for[@]}"; do
    if [ "$pkg" = unbound ] || [ "$pkg" = libunbound8 ] || [ -n "$(installed_version "$pkg")" ]; then
        selected+=("$pkg")
    fi
done

# --------------------------------------------------------------------------
# Pre-flight: does the current config work with the new version?
# --------------------------------------------------------------------------
if [ -f /etc/unbound/unbound.conf ]; then
    # Unpacked under /var rather than /tmp, which is mounted noexec on some servers.
    preflight="$CACHE_DIR/.preflight"
    rm -rf "$preflight"
    mkdir -p "$preflight"
    dpkg-deb -x "${deb_for[unbound]}" "$preflight"
    rc=0
    out=$("$preflight/usr/sbin/unbound-checkconf" /etc/unbound/unbound.conf 2>&1) || rc=$?
    rm -rf "$preflight"
    if [ "$rc" = 0 ]; then
        log "config check with the new version passed"
    elif [ "$rc" = 126 ] || [ "$rc" = 127 ] || [[ $out == *"error while loading shared libraries"* ]]; then
        warn "could not run the new unbound-checkconf before installing; the config is checked after installing instead"
    else
        printf '%s\n' "$out" >&2
        die "your config does not pass the new version's checks; nothing was changed"
    fi
fi

# --------------------------------------------------------------------------
# Remember how things work right now, and keep the current packages on disk.
# --------------------------------------------------------------------------
was_active=0
systemctl is-active --quiet unbound 2>/dev/null && was_active=1

dns_lookup() {
    local answer
    command -v dig >/dev/null 2>&1 || return 2
    answer=$(dig +time=3 +tries=2 -p "$CHECK_PORT" "@$CHECK_SERVER" "$CHECK_NAME" A 2>/dev/null) || return 1
    case $answer in
        *"status: NOERROR"*) return 0 ;;
        *) return 1 ;;
    esac
}

dns_was_ok=0
if [ "$was_active" = 1 ]; then
    if dns_lookup; then
        dns_was_ok=1
    else
        case $? in
            2) warn "dig is not installed (apt install bind9-dnsutils); skipping the DNS lookup check" ;;
            *) warn "a lookup of $CHECK_NAME via $CHECK_SERVER#$CHECK_PORT fails already, before the upgrade; only the service state will be checked" ;;
        esac
    fi
fi

cached_deb() {
    local f
    for f in "$1/$2_"*.deb; do
        if [ -e "$f" ]; then
            printf '%s\n' "$f"
            return 0
        fi
    done
    return 1
}

rollback=()
if [ -n "$CUR_VERSION" ]; then
    mkdir -p "$CACHE_DIR"
    for pkg in "${selected[@]}"; do
        old=$(installed_version "$pkg")
        [ -n "$old" ] || continue
        dir="$CACHE_DIR/$old"
        mkdir -p "$dir"
        if ! copy=$(cached_deb "$dir" "$pkg"); then
            (cd "$dir" && apt-get download -q "$pkg=$old" >/dev/null 2>&1) || true
            copy=$(cached_deb "$dir" "$pkg") || copy=
        fi
        if [ -n "$copy" ]; then
            rollback+=("$copy")
        elif [ "$force" = 1 ]; then
            warn "no copy of $pkg $old for rollback (continuing because of --force)"
        else
            die "cannot get a copy of $pkg $old to roll back to; try again later or use --force"
        fi
    done
fi

if [ -d /etc/unbound ]; then
    backup="$BACKUP_DIR/unbound-etc-$(date +%Y%m%d-%H%M%S).tar.gz"
    tar -czf "$backup" -C / etc/unbound
    log "config backed up to $backup"
fi

health_check() {
    if [ "$was_active" = 1 ]; then
        for _ in $(seq 1 30); do
            systemctl is-active --quiet unbound && break
            sleep 1
        done
        systemctl is-active --quiet unbound || { warn "unbound is not running"; return 1; }
    fi
    if [ -f /etc/unbound/unbound.conf ] && ! unbound-checkconf /etc/unbound/unbound.conf >/dev/null; then
        warn "unbound-checkconf failed"
        return 1
    fi
    if [ "$dns_was_ok" = 1 ]; then
        for _ in 1 2 3 4 5; do
            dns_lookup && return 0
            sleep 2
        done
        warn "lookup of $CHECK_NAME via $CHECK_SERVER#$CHECK_PORT failed"
        return 1
    fi
    return 0
}

apt_install_debs() {
    apt-get install -y --no-install-recommends --allow-downgrades \
        -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold "$@"
}

do_rollback() {
    if [ ${#rollback[@]} -eq 0 ]; then
        die "the upgrade failed and there is no previous version to go back to; config backup: ${backup:-none}"
    fi
    warn "rolling back to $CUR_VERSION"
    dpkg --configure -a || true
    if apt_install_debs "${rollback[@]}"; then
        if [ "$was_active" = 1 ]; then
            systemctl restart unbound || true
        fi
        if health_check; then
            die "the upgrade to $NEW_VERSION failed; rolled back to $CUR_VERSION (journalctl -u unbound shows why)"
        fi
    fi
    die "the upgrade failed AND the rollback did not fully work; check 'systemctl status unbound'; config backup: ${backup:-none}"
}

# --------------------------------------------------------------------------
# Upgrade.
# --------------------------------------------------------------------------
log "updating package lists"
apt-get update -q >/dev/null 2>&1 || warn "apt-get update failed; continuing with cached lists"

install_list=()
for pkg in "${selected[@]}"; do
    install_list+=("${deb_for[$pkg]}")
done
log "installing: ${selected[*]}"
if ! apt_install_debs "${install_list[@]}"; then
    do_rollback
fi

# Make sure the new binary is the one running (the package usually restarts
# it already; a second restart costs about a second).
if [ "$was_active" = 1 ]; then
    systemctl restart unbound || true
fi

if ! health_check; then
    do_rollback
fi

# Keep the installed packages for future rollbacks; drop the oldest versions.
mkdir -p "$CACHE_DIR/$NEW_VERSION"
cp "${install_list[@]}" "$CACHE_DIR/$NEW_VERSION/"
versions=()
for d in "$CACHE_DIR"/*/; do
    [ -d "$d" ] && versions+=("$(basename "$d")")
done
if [ ${#versions[@]} -gt "$KEEP_VERSIONS" ]; then
    mapfile -t sorted < <(printf '%s\n' "${versions[@]}" | sort -V)
    to_remove=$(( ${#sorted[@]} - KEEP_VERSIONS ))
    for v in "${sorted[@]:0:$to_remove}"; do
        rm -rf "${CACHE_DIR:?}/$v"
    done
fi

log "unbound is now $(installed_version unbound)"
unbound -V 2>/dev/null | head -n 1 || true
