#!/bin/bash
# Default-deny egress firewall for blast containers.
#
# Derived from anthropics/claude-code .devcontainer/init-firewall.sh:
#   - kept: default-deny posture, GitHub meta IP ranges, self-verification at the end
#   - trimmed: VS Code marketplace/update domains (CLI-driven container, no VS Code server)
#   - kept sentry/statsig in the defaults so Claude Code telemetry fails quietly
#
# This script is byte-identical in every consumer. What differs is configuration,
# and configuration arrives through the environment:
#
#   BLAST_REQUIRED_DOMAINS    space-separated; abort if any is unresolvable.
#                             api.anthropic.com and registry.npmjs.org are always
#                             prepended and cannot be removed - a consumer must not
#                             be able to lock Claude Code out of its own API.
#   BLAST_OPTIONAL_DOMAINS    space-separated; warn and skip if unresolvable.
#                             Default: sentry.io statsig.anthropic.com statsig.com
#   BLAST_ALLOW_GITHUB        true|false (default true). Fetch and allowlist the
#                             published GitHub IP ranges.
#   BLAST_ALLOW_HOST_NETWORK  true|false (default true). Allow the Docker gateway
#                             /24 - this is the rule that lets the container reach
#                             a service on the host, or a compose sidecar.
#
# Run as root via the single sudoers exemption granted to node:
#   sudo /usr/local/bin/init-firewall.sh

set -euo pipefail
IFS=$'\n\t'

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

# Non-removable base requirements: prepended, never replaced.
BLAST_BASE_REQUIRED_DOMAINS="api.anthropic.com registry.npmjs.org"

BLAST_REQUIRED_DOMAINS="${BLAST_REQUIRED_DOMAINS:-}"
BLAST_OPTIONAL_DOMAINS="${BLAST_OPTIONAL_DOMAINS:-sentry.io statsig.anthropic.com statsig.com}"
BLAST_ALLOW_GITHUB="${BLAST_ALLOW_GITHUB:-true}"
BLAST_ALLOW_HOST_NETWORK="${BLAST_ALLOW_HOST_NETWORK:-true}"

# Test-harness seam ONLY: lets test/smoke.sh point the meta fetch at a local stub
# to prove the fail-closed path. Never set this in a real consumer.
BLAST_GITHUB_META_URL="${BLAST_GITHUB_META_URL:-https://api.github.com/meta}"

# Collapse any run of whitespace into one token per line, dropping blanks.
split_tokens() {
    echo "${1:-}" | tr -s ' \t\n' '\n' | sed '/^$/d'
}

# An environment variable is an injection surface: these tokens are interpolated
# into dig and ipset calls, so anything outside the hostname alphabet is fatal.
validate_domain() {
    if [[ ! "$1" =~ ^[A-Za-z0-9.-]+$ ]]; then
        echo "ERROR: invalid domain token in BLAST_* configuration: '$1'" >&2
        exit 1
    fi
}

validate_bool() {
    if [[ "$2" != "true" && "$2" != "false" ]]; then
        echo "ERROR: $1 must be 'true' or 'false', got '$2'" >&2
        exit 1
    fi
}

validate_bool BLAST_ALLOW_GITHUB "$BLAST_ALLOW_GITHUB"
validate_bool BLAST_ALLOW_HOST_NETWORK "$BLAST_ALLOW_HOST_NETWORK"

REQUIRED_DOMAINS=()
while IFS= read -r d; do
    validate_domain "$d"
    REQUIRED_DOMAINS+=("$d")
done < <(split_tokens "$BLAST_BASE_REQUIRED_DOMAINS $BLAST_REQUIRED_DOMAINS")

OPTIONAL_DOMAINS=()
while IFS= read -r d; do
    validate_domain "$d"
    OPTIONAL_DOMAINS+=("$d")
done < <(split_tokens "$BLAST_OPTIONAL_DOMAINS")

# Log the effective boundary so an operator can read what it actually is straight
# out of the postStart output, without reverse-engineering it from devcontainer.json.
echo "=== blast firewall configuration ==="
echo "  image version       : ${BLAST_BASE_VERSION:-unknown}"
echo "  required domains    : ${REQUIRED_DOMAINS[*]}"
if [ ${#OPTIONAL_DOMAINS[@]} -gt 0 ]; then
    echo "  optional domains    : ${OPTIONAL_DOMAINS[*]}"
else
    echo "  optional domains    : (none)"
fi
echo "  allow github ranges : $BLAST_ALLOW_GITHUB"
echo "  allow host network  : $BLAST_ALLOW_HOST_NETWORK"
if [ "$BLAST_GITHUB_META_URL" != "https://api.github.com/meta" ]; then
    echo "  github meta url     : $BLAST_GITHUB_META_URL   *** TEST OVERRIDE ***"
fi
echo "===================================="

# ---------------------------------------------------------------------------
# Reset
# ---------------------------------------------------------------------------

# 1. Extract Docker DNS info BEFORE any flushing
DOCKER_DNS_RULES=$(iptables-save -t nat | grep "127\.0\.0\.11" || true)

# DEFECT FIX 1 - idempotency / restart deadlock.
# A previous run leaves the OUTPUT policy at DROP, and flushing rules does NOT
# reset the chain policy. On a second run the DNS lookups and the /meta fetch
# below would then be dropped, and the script would hang until their timeouts -
# a restart deadlock. Reset the policies to ACCEPT before flushing; default-deny
# is re-applied at the end, so the open window is this script's own runtime.
iptables -P INPUT ACCEPT
iptables -P FORWARD ACCEPT
iptables -P OUTPUT ACCEPT

iptables -F
iptables -X
iptables -t nat -F
iptables -t nat -X
iptables -t mangle -F
iptables -t mangle -X
ipset destroy allowed-domains 2>/dev/null || true

# 2. Selectively restore ONLY internal Docker DNS resolution.
# This is what lets a compose consumer resolve a sidecar by service name after
# the flush. If sidecar resolution breaks, this block is the first suspect.
if [ -n "$DOCKER_DNS_RULES" ]; then
    echo "Restoring Docker DNS rules..."
    iptables -t nat -N DOCKER_OUTPUT 2>/dev/null || true
    iptables -t nat -N DOCKER_POSTROUTING 2>/dev/null || true
    echo "$DOCKER_DNS_RULES" | xargs -L 1 iptables -t nat
else
    echo "No Docker DNS rules to restore"
fi

# DNS and localhost first
iptables -A OUTPUT -p udp --dport 53 -j ACCEPT
iptables -A INPUT -p udp --sport 53 -j ACCEPT
iptables -A INPUT -i lo -j ACCEPT
iptables -A OUTPUT -o lo -j ACCEPT
# NOTE: the reference script also opens outbound SSH (port 22). Deliberately omitted -
# no push credentials live in this container, so nothing should be speaking SSH.

# Create ipset with CIDR support
ipset create allowed-domains hash:net

# ---------------------------------------------------------------------------
# Allowlist
# ---------------------------------------------------------------------------

if [ "$BLAST_ALLOW_GITHUB" = "true" ]; then
    echo "Fetching GitHub IP ranges from $BLAST_GITHUB_META_URL ..."

    # DEFECT FIX 2 - /meta failure modes must fail closed.
    # A rate-limited or otherwise non-2xx response still carries a non-empty JSON
    # body, and the old emptiness test passed it straight through to the
    # structural check. --fail turns any non-2xx into a curl error before the body
    # is ever inspected; one retry absorbs a transient blip; anything still
    # failing exits non-zero. There is deliberately no "no GitHub ranges,
    # continue" fall-through - a firewall that silently drops its allowlist is
    # worse than one that refuses to start.
    gh_ranges=""
    if ! gh_ranges=$(curl -sS --fail --max-time 15 "$BLAST_GITHUB_META_URL" 2>/dev/null); then
        echo "WARN: GitHub meta fetch failed; retrying once in 5s..."
        sleep 5
        if ! gh_ranges=$(curl -sS --fail --max-time 15 "$BLAST_GITHUB_META_URL" 2>/dev/null); then
            echo "ERROR: Failed to fetch GitHub IP ranges from $BLAST_GITHUB_META_URL (non-2xx, timeout, or DNS failure)." >&2
            echo "ERROR: Failing closed. If this consumer genuinely has no GitHub need, set BLAST_ALLOW_GITHUB=false." >&2
            exit 1
        fi
    fi

    if ! echo "$gh_ranges" | jq -e '.web and .api and .git' >/dev/null 2>&1; then
        echo "ERROR: GitHub meta response is missing required fields (.web/.api/.git) - failing closed." >&2
        exit 1
    fi

    echo "Processing GitHub IPs..."
    while read -r cidr; do
        if [[ ! "$cidr" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}/[0-9]{1,2}$ ]]; then
            echo "ERROR: Invalid CIDR range from GitHub meta: $cidr" >&2
            exit 1
        fi
        ipset add allowed-domains "$cidr"
    done < <(echo "$gh_ranges" | jq -r '(.web + .api + .git)[]' | aggregate -q)
else
    echo "Skipping GitHub IP ranges (BLAST_ALLOW_GITHUB=false)"
fi

# Required domains - abort if unresolvable (these ARE load-bearing)
for domain in "${REQUIRED_DOMAINS[@]}"; do
    echo "Resolving $domain..."
    ips=$(dig +noall +answer A "$domain" | awk '$4 == "A" {print $5}')
    if [ -z "$ips" ]; then
        echo "ERROR: Failed to resolve required domain $domain" >&2
        exit 1
    fi
    while read -r ip; do
        if [[ ! "$ip" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
            echo "ERROR: Invalid IP from DNS for $domain: $ip" >&2
            exit 1
        fi
        ipset add allowed-domains "$ip"
    done < <(echo "$ips")
done

# Optional domains (telemetry) - warn and skip if unresolvable
if [ ${#OPTIONAL_DOMAINS[@]} -gt 0 ]; then
    for domain in "${OPTIONAL_DOMAINS[@]}"; do
        echo "Resolving $domain (optional)..."
        ips=$(dig +noall +answer A "$domain" | awk '$4 == "A" {print $5}')
        if [ -z "$ips" ]; then
            echo "WARN: could not resolve optional domain $domain - skipping (it will fail closed)"
            continue
        fi
        while read -r ip; do
            [[ "$ip" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]] && ipset add allowed-domains "$ip"
        done < <(echo "$ips")
    done
fi

# Host network (Docker gateway) access. This is also the /24 that a compose
# sidecar sits on; the sidecar is additionally allowlisted by service name above,
# so the boundary still holds with BLAST_ALLOW_HOST_NETWORK=false.
if [ "$BLAST_ALLOW_HOST_NETWORK" = "true" ]; then
    HOST_IP=$(ip route | grep default | cut -d" " -f3)
    if [ -z "$HOST_IP" ]; then
        echo "ERROR: Failed to detect host IP" >&2
        exit 1
    fi
    HOST_NETWORK=$(echo "$HOST_IP" | sed "s/\.[0-9]*$/.0\/24/")
    echo "Host network detected as: $HOST_NETWORK"
    iptables -A INPUT -s "$HOST_NETWORK" -j ACCEPT
    iptables -A OUTPUT -d "$HOST_NETWORK" -j ACCEPT
else
    echo "Skipping host network rule (BLAST_ALLOW_HOST_NETWORK=false)"
fi

# ---------------------------------------------------------------------------
# Default-deny
# ---------------------------------------------------------------------------

iptables -P INPUT DROP
iptables -P FORWARD DROP
iptables -P OUTPUT DROP

# Established connections
iptables -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
iptables -A OUTPUT -m state --state ESTABLISHED,RELATED -j ACCEPT

# Allowlisted destinations only
iptables -A OUTPUT -m set --match-set allowed-domains dst -j ACCEPT

# Reject everything else with immediate feedback
iptables -A OUTPUT -j REJECT --reject-with icmp-admin-prohibited

echo "Firewall configuration complete"

# ---------------------------------------------------------------------------
# Self-verification
# ---------------------------------------------------------------------------

echo "Verifying firewall rules..."

if curl --connect-timeout 5 -s https://example.com >/dev/null 2>&1; then
    echo "ERROR: Firewall verification failed - was able to reach https://example.com" >&2
    exit 1
else
    echo "Firewall verification passed - unable to reach https://example.com as expected"
fi

if [ "$BLAST_ALLOW_GITHUB" = "true" ]; then
    if ! curl --connect-timeout 5 -s https://api.github.com/zen >/dev/null 2>&1; then
        echo "ERROR: Firewall verification failed - unable to reach https://api.github.com" >&2
        exit 1
    fi
    echo "Firewall verification passed - able to reach https://api.github.com as expected"
else
    echo "Skipping GitHub reachability check (BLAST_ALLOW_GITHUB=false)"
fi

# The first required domain is always a base requirement (api.anthropic.com).
# Any HTTP status proves routing; we are deliberately not asserting a 200.
FIRST_REQUIRED="${REQUIRED_DOMAINS[0]}"
if ! curl -sI --connect-timeout 5 "https://${FIRST_REQUIRED}" >/dev/null 2>&1; then
    echo "ERROR: Firewall verification failed - unable to reach https://${FIRST_REQUIRED}" >&2
    exit 1
fi
echo "Firewall verification passed - able to reach https://${FIRST_REQUIRED} as expected"
