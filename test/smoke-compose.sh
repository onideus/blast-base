#!/usr/bin/env bash
# Sidecar-through-firewall proof.
#
# This is the riskiest path in the design. init-firewall.sh flushes the nat
# table, and Docker's embedded DNS (127.0.0.11) lives there. If the DOCKER_OUTPUT
# restore block is wrong, compose service names stop resolving and every
# compose-mode consumer breaks in a way that looks like a database problem.
# Assert it explicitly rather than discovering it downstream.
#
#   test/smoke-compose.sh

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IMAGE="${BLAST_TEST_IMAGE:-blast-base:test}"
COMPOSE_FILE="$REPO_ROOT/test/compose.smoke.yml"
PROJECT="blast-smoke-$$"

cleanup() {
    docker compose -p "$PROJECT" -f "$COMPOSE_FILE" down -v --remove-orphans >/dev/null 2>&1 || true
}
trap cleanup EXIT

echo "==> Building $IMAGE"
docker build -t "$IMAGE" "$REPO_ROOT"

echo "==> Bringing up the compose stack"
BLAST_TEST_IMAGE="$IMAGE" docker compose -p "$PROJECT" -f "$COMPOSE_FILE" up -d --wait

echo "==> Assertions inside the blast service"
docker compose -p "$PROJECT" -f "$COMPOSE_FILE" exec -T blast bash -euo pipefail -c '
fail() { echo "  FAIL: $*" >&2; exit 1; }
pass() { echo "  PASS: $*"; }

if ! getent hosts sidecar >/dev/null 2>&1; then
    fail "sidecar does not resolve even before the firewall runs"
fi
pass "sidecar resolves before the firewall runs"

if ! out=$(sudo /usr/local/bin/init-firewall.sh 2>&1); then
    echo "$out"
    fail "firewall run failed in compose mode"
fi
echo "$out" | sed "s/^/      | /"

if ! echo "$out" | grep -q "Resolving sidecar"; then
    fail "firewall did not treat sidecar as a required domain"
fi
pass "firewall resolved and allowlisted sidecar"

if ! getent hosts sidecar >/dev/null 2>&1; then
    fail "sidecar stopped resolving after the flush - Docker DNS nat restore is broken"
fi
pass "Docker embedded DNS survived the nat flush"

# pg_isready is not in the base image - no toolchain beyond Node lives here - so
# prove the TCP path directly. bash /dev/tcp opens a real connection, which is
# what we actually care about: does traffic to the sidecar survive default-deny.
if ! timeout 5 bash -c "cat < /dev/null > /dev/tcp/sidecar/5432" 2>/dev/null; then
    fail "sidecar:5432 not reachable through the firewall"
fi
pass "sidecar:5432 reachable through the firewall"

if curl --connect-timeout 5 -s https://example.com >/dev/null 2>&1; then
    fail "example.com reachable - default-deny is not holding in compose mode"
fi
pass "example.com still rejected in compose mode"
'

echo
echo "==> compose smoke passed"
