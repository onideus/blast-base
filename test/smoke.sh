#!/usr/bin/env bash
# blast-base smoke test: build the image, then prove the boundary actually holds.
#
# Requires a moby/Docker engine that permits --cap-add=NET_ADMIN. Run from
# anywhere; paths resolve against the repo root.
#
#   test/smoke.sh
#
# Override the image tag with BLAST_TEST_IMAGE if you need to.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IMAGE="${BLAST_TEST_IMAGE:-blast-base:test}"
CAPS=(--cap-add=NET_ADMIN --cap-add=NET_RAW)

echo "==> Building $IMAGE"
docker build -t "$IMAGE" "$REPO_ROOT"

echo
echo "==> Test 1: default configuration"
docker run --rm "${CAPS[@]}" -e BLAST_REQUIRED_DOMAINS="" "$IMAGE" bash -euo pipefail -c '
fail() { echo "  FAIL: $*" >&2; exit 1; }
pass() { echo "  PASS: $*"; }

if ! out=$(sudo /usr/local/bin/init-firewall.sh 2>&1); then
    echo "$out"
    fail "first firewall run exited non-zero"
fi
if ! echo "$out" | grep -q "Firewall configuration complete"; then
    echo "$out"
    fail "first run did not reach completion"
fi
pass "firewall completes on first run"

# The banner only prints if the script ran with its configuration block intact.
# If env_keep is ever dropped from the sudoers rule, the BLAST_* variables stop
# crossing the sudo boundary and every consumer silently gets the defaults -
# this assertion plus Test 3 are what catch that.
if ! echo "$out" | grep -q "blast firewall configuration"; then
    echo "$out"
    fail "configuration banner missing"
fi
pass "configuration banner emitted"

# DEFECT 1: a second run must not deadlock against the DROP policy left behind
# by the first. Before the fix this hung until the DNS and curl timeouts.
if ! out2=$(timeout 120 sudo /usr/local/bin/init-firewall.sh 2>&1); then
    echo "$out2"
    fail "second firewall run exited non-zero or timed out (defect 1 regression)"
fi
if ! echo "$out2" | grep -q "Firewall configuration complete"; then
    echo "$out2"
    fail "second run did not reach completion (defect 1 regression)"
fi
pass "firewall is idempotent across a second run (defect 1)"

if curl --connect-timeout 5 -s https://example.com >/dev/null 2>&1; then
    fail "example.com was reachable - default-deny is not holding"
fi
pass "example.com rejected"

if ! curl --connect-timeout 5 -s https://api.github.com/zen >/dev/null 2>&1; then
    fail "api.github.com unreachable"
fi
pass "api.github.com reachable"

if ! curl -sI --connect-timeout 5 https://api.anthropic.com >/dev/null 2>&1; then
    fail "api.anthropic.com unreachable"
fi
pass "api.anthropic.com reachable"

if ! claude --version >/dev/null 2>&1; then
    fail "claude --version failed"
fi
pass "claude CLI present: $(claude --version 2>&1 | head -1)"

if [ -z "${BLAST_BASE_VERSION:-}" ]; then
    fail "BLAST_BASE_VERSION is empty"
fi
pass "BLAST_BASE_VERSION=$BLAST_BASE_VERSION"

if command -v docker >/dev/null 2>&1; then
    fail "docker CLI is present inside the container"
fi
pass "no docker CLI inside the container"
'

echo
echo "==> Test 2: BLAST_ALLOW_GITHUB=false"
docker run --rm "${CAPS[@]}" \
    -e BLAST_REQUIRED_DOMAINS="" \
    -e BLAST_ALLOW_GITHUB=false \
    "$IMAGE" bash -euo pipefail -c '
fail() { echo "  FAIL: $*" >&2; exit 1; }
pass() { echo "  PASS: $*"; }

if ! out=$(sudo /usr/local/bin/init-firewall.sh 2>&1); then
    echo "$out"
    fail "run with BLAST_ALLOW_GITHUB=false exited non-zero"
fi
if echo "$out" | grep -q "Fetching GitHub IP ranges"; then
    echo "$out"
    fail "meta fetch was attempted despite BLAST_ALLOW_GITHUB=false"
fi
if ! echo "$out" | grep -q "Firewall configuration complete"; then
    echo "$out"
    fail "did not reach completion"
fi
pass "BLAST_ALLOW_GITHUB=false skips the meta fetch and still completes"
'

echo
echo "==> Test 3: a 403 from the meta endpoint must fail closed (defect 2)"
# The stub is a local Node one-liner returning 403 with a non-empty JSON body -
# exactly the rate-limit shape that used to slip past the old emptiness check.
# BLAST_GITHUB_META_URL is a test-only seam; see init-firewall.sh.
set +e
docker run --rm "${CAPS[@]}" \
    -e BLAST_REQUIRED_DOMAINS="" \
    -e BLAST_GITHUB_META_URL="http://127.0.0.1:8099/meta" \
    "$IMAGE" bash -c '
node -e "require(\"http\").createServer(function(q,s){s.writeHead(403,{\"Content-Type\":\"application/json\"});s.end(JSON.stringify({message:\"API rate limit exceeded\"}))}).listen(8099,\"127.0.0.1\")" &
for i in $(seq 1 25); do
    if curl -s -o /dev/null "http://127.0.0.1:8099/meta"; then break; fi
    sleep 0.2
done
sudo /usr/local/bin/init-firewall.sh
'
rc=$?
set -e
if [ "$rc" -eq 0 ]; then
    echo "  FAIL: a 403 from the meta endpoint did not fail closed (defect 2 regression)" >&2
    exit 1
fi
echo "  PASS: GitHub meta 403 fails closed (exit $rc) (defect 2)"

echo
echo "==> smoke passed"
