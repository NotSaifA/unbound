# unbound for Ubuntu 24.04, built somewhere else

Ubuntu 24.04 ships unbound 1.19.2 with selected security fixes backported.
This repository builds the current unbound release as normal `.deb` packages
for Ubuntu 24.04 on another machine (GitHub's servers or your own computer),
so your VPS only has to install them.

How it works:

- **Packaging comes from Debian.** Debian's unbound maintainers package each
  upstream release, usually on the day it comes out. `build-unbound.sh`
  downloads their source package, checks it against Debian's archive signing
  keys, and rebuilds it against Ubuntu 24.04's libraries in a clean
  `ubuntu:24.04` container.
- **Drop-in replacement.** Ubuntu's unbound package is derived from Debian's,
  so the package names, `/etc/unbound` layout and `unbound` service stay the
  same, and your config is kept. The version (e.g. `1.26.1-1~ubuntu24.04.1`)
  is higher than Ubuntu's, so `apt upgrade` will not swap it back.
- **Safe updates on the server.** `update-unbound.sh` checks your config with
  the new version before installing, keeps the old packages on disk, and rolls
  back by itself if the service or a test lookup fails afterwards.

## Option A: GitHub builds it for you (fully automatic)

1. Create a new GitHub repository (public is simplest: Actions minutes are
   free and the server can download releases without a token).
2. Add everything in this folder, including the `.github/workflows` and `ci`
   folders (drag the whole folder onto the repository page, or `git push`).
3. In the repository, open **Actions**, enable workflows if asked, choose
   **Build unbound for Ubuntu 24.04**, and click **Run workflow**.

The first run takes roughly 15 minutes. After that it checks Debian every six
hours and publishes a new release only when there is a new version, and only
after these tests pass:

- install on a fresh Ubuntu 24.04 system
- upgrade Ubuntu's own unbound with `update-unbound.sh`
- DNSSEC still works (a signed zone validates, a broken one is rejected)

## Option B: build on your own computer and copy it over

Any machine with Docker (Linux, macOS, or Windows with WSL) works:

```sh
bash build-unbound.sh --docker              # VPS is x86_64 (amd64)
NOCHECK=1 bash build-unbound.sh --docker --arch arm64   # ARM VPS (emulated, slower)
scp out/unbound-noble-amd64.tar.gz* update-unbound.sh you@your-vps:
```

Then on the VPS:

```sh
sudo bash update-unbound.sh --file unbound-noble-amd64.tar.gz
```

The build matches the machine it runs on, so an Apple Silicon Mac builds
`arm64` by default; add `--arch amd64` for an x86 VPS. Building for the other
architecture runs under emulation and needs it set up once:
`docker run --privileged --rm tonistiigi/binfmt --install all`.

## On the VPS

```sh
curl -fsSLO https://raw.githubusercontent.com/OWNER/REPO/main/update-unbound.sh
sudo bash update-unbound.sh --repo OWNER/REPO            # update now
bash update-unbound.sh --repo OWNER/REPO --check         # just compare versions
sudo bash update-unbound.sh --repo OWNER/REPO --install-timer   # daily, automatic
```

`--install-timer` copies the script to `/usr/local/sbin`, saves the repository
name in `/etc/default/unbound-update`, and enables a daily systemd timer. Its
output is in `journalctl -u unbound-update`.

If unbound listens somewhere other than `127.0.0.1:53` (Pi-hole setups often
use port 5335), tell the health check in `/etc/default/unbound-update`:

```sh
CHECK_SERVER=127.0.0.1
CHECK_PORT=5335
```

The DNS lookup check uses `dig`; install it with
`sudo apt install bind9-dnsutils` if it is missing.

## Going back to Ubuntu's package

```sh
apt-cache policy unbound          # shows Ubuntu's version, e.g. 1.19.2-1ubuntu3.x
sudo apt install --allow-downgrades unbound=<that version> \
    unbound-anchor=<that version> libunbound8=<that version>
```

Config backups from every update are in `/var/backups/unbound-etc-*.tar.gz`,
and recent package versions are kept in `/var/cache/unbound-update/`.

## Notes

- **ARM VPS:** in `.github/workflows/build.yml`, uncomment the `arm64` lines.
  GitHub's ARM runners are free for public repositories.
- **Private repository:** works, but the server then needs the `gh` CLI and a
  read-only token: add `GH_TOKEN=...` to `/etc/default/unbound-update` and
  `chmod 600` that file.
- **Scheduled runs pause after 60 days** without commits to a public
  repository. GitHub emails you; one click on **Enable workflow** turns them
  back on.
- **Debian's signing keys:** the script pins Debian's 12 and 13 archive keys.
  When Debian starts signing with a new key, the build stops with a signature
  error; add the new key from https://ftp-master.debian.org/keys.html to
  `DEBIAN_KEYS` in `build-unbound.sh` (or `EXTRA_DEBIAN_KEYS`).
- **Rebuilding the same version** (for example after changing a build
  setting): raise `BUILD_REV` in the workflow.
- **Trust:** the sources are verified against Debian's keys and build
  dependencies come from Ubuntu's archive; the published bundles are only as
  trustworthy as your GitHub account, so turn on two-factor authentication.
