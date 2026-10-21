#!/usr/bin/env bash
# test-fresh.sh - install the built packages on a stock Ubuntu 24.04 container
# (proves every dependency comes from the Ubuntu archive) and resolve with them.
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

apt-get update -qq
apt-get install -y --no-install-recommends /out/debs/*.deb \
    bind9-dnsutils dns-root-data ca-certificates > /dev/null

unbound -V | head -n 3
id unbound
if dpkg-query -W python3-unbound > /dev/null 2>&1; then
    python3 -c 'import unbound; print("python3-unbound", unbound.ub_version())'
fi

# There is no systemd in the container, so do what the service unit does
# before starting unbound: put the root trust anchor in place.
if [ -x /usr/libexec/unbound-helper ]; then
    /usr/libexec/unbound-helper root_trust_anchor_update || true
fi
if [ ! -s /var/lib/unbound/root.key ]; then
    mkdir -p /var/lib/unbound
    unbound-anchor -a /var/lib/unbound/root.key || true
    chown -R unbound: /var/lib/unbound
fi
[ -s /var/lib/unbound/root.key ] || { echo "FAIL: no root trust anchor"; exit 1; }

# Containers usually have no IPv6, not even on loopback.
printf 'server:\n    do-ip6: no\n' > /etc/unbound/unbound.conf.d/zz-ci.conf
unbound-checkconf

unbound -d -p -c /etc/unbound/unbound.conf &
pid=$!
trap 'kill "$pid" 2>/dev/null || true' EXIT

bash "$(dirname "$0")/dns-checks.sh" 127.0.0.1 53
