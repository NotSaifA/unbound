#!/usr/bin/env bash
# test-upgrade.sh OUT_DIR - on a real Ubuntu 24.04 machine with systemd: install
# Ubuntu's own unbound, then upgrade it with update-unbound.sh, exactly like on
# a server, and check that it still resolves and validates.
set -euo pipefail

out=${1:?usage: test-upgrade.sh OUT_DIR}
here=$(cd "$(dirname "$0")" && pwd)
bundle="$out/unbound-noble-$(dpkg --print-architecture).tar.gz"
export DEBIAN_FRONTEND=noninteractive NEEDRESTART_SUSPEND=1

apt-get update -qq
apt-get install -y unbound bind9-dnsutils > /dev/null
old=$(dpkg-query -W -f='${Version}' unbound)
echo "Ubuntu's unbound: $old"

for _ in $(seq 1 30); do
    systemctl is-active --quiet unbound && break
    sleep 1
done
systemctl is-active --quiet unbound || { systemctl status unbound --no-pager; exit 1; }
bash "$here/dns-checks.sh" 127.0.0.1 53

bash "$here/../update-unbound.sh" --file "$bundle"

new=$(dpkg-query -W -f='${Version}' unbound)
echo "after update-unbound.sh: $new"
dpkg --compare-versions "$new" gt "$old" || { echo "FAIL: unbound was not upgraded"; exit 1; }
systemctl is-active --quiet unbound || { systemctl status unbound --no-pager; exit 1; }
bash "$here/dns-checks.sh" 127.0.0.1 53

# Running it again must change nothing.
bash "$here/../update-unbound.sh" --file "$bundle" | tee /tmp/second-run.log
grep -q 'up to date' /tmp/second-run.log || { echo "FAIL: second run was not a no-op"; exit 1; }

journalctl -u unbound --no-pager -n 20 || true
