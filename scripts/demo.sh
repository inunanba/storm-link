#!/usr/bin/env bash
# Two-minute demo: start IRIS + worker, replay two storms, run all native tests.
set -euo pipefail
cd "$(dirname "$0")/.."
docker compose up -d --build
echo "Waiting for IRIS to load Storm classes and start the Production..."
for _ in $(seq 60); do
  docker compose ps iris | grep -q '(healthy)' && break
  sleep 3
done
docker compose ps iris | grep -q '(healthy)' || { echo "IRIS not healthy; see Troubleshooting in README"; exit 1; }
echo "== Replay C01 (clear storm) and A1 (ambiguous storm) =="
docker compose exec -T iris iris session IRIS -U USER < scripts/replay.script | grep -aE '^(CASE|PAYLOAD)='
echo "== Native tests =="
docker compose exec -T iris iris session IRIS -U USER < scripts/runtests.script | tee /tmp/storm-native-tests.log | grep -aE '^(All PASSED:|FAILED)'
echo "Portal: http://${STORM_PORTAL_BIND:-127.0.0.1:52774}/csp/user/EnsPortal.VisualTrace.zen?SESSIONID=5"
