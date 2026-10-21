#!/usr/bin/env bash
# dns-checks.sh [SERVER] [PORT] - check that unbound resolves and validates DNSSEC.
set -euo pipefail

server=${1:-127.0.0.1}
port=${2:-53}

query() { dig +time=5 +tries=3 -p "$port" "@$server" "$@"; }

for _ in $(seq 1 30); do
    query . SOA >/dev/null 2>&1 && break
    sleep 1
done

out=$(query +dnssec nlnetlabs.nl A || true)
if ! grep -q 'status: NOERROR' <<< "$out"; then
    printf '%s\n' "$out"
    echo "FAIL: nlnetlabs.nl did not resolve"
    exit 1
fi
if ! grep -Eq '^;; flags:[^;]* ad[ ;]' <<< "$out"; then
    printf '%s\n' "$out"
    echo "FAIL: the answer for a signed zone was not DNSSEC-validated (no ad flag)"
    exit 1
fi
echo "ok: nlnetlabs.nl resolves and validates (ad flag set)"

# dnssec-failed.org is deliberately signed wrong; a validating resolver must refuse it.
out=$(query dnssec-failed.org A || true)
case $out in
    *"status: SERVFAIL"*)
        echo "ok: dnssec-failed.org (broken signatures) is rejected" ;;
    *"status: NXDOMAIN"*)
        echo "warning: dnssec-failed.org no longer exists; bogus-signature check skipped" ;;
    *)
        printf '%s\n' "$out"
        echo "FAIL: a zone with broken signatures was not rejected"
        exit 1 ;;
esac
