# blast-base

Shared substrate image for **blast containers**: a containment boundary for
running coding agents with broad autonomy inside a repo, without giving them the
host.

The boundary is four things:

- **Default-deny egress.** Nothing leaves except an explicitly declared allowlist.
- **Repo-only mount.** The working repo at `/workspace`, and nothing else from the host.
- **Credential exclusion.** Claude config lives in a named volume, never the host keychain. No push credentials, no SSH keys.
- **A non-editable boundary.** A consumer's `.devcontainer/` is human-review-only; the base moves only by tag.

Derived from the [anthropics/claude-code](https://github.com/anthropics/claude-code)
reference devcontainer.

## Why this exists

Three repos needed the same boundary, and each carried a hand-edited copy of
~200 lines of Dockerfile, firewall script, and `devcontainer.json` that differed
only in the toolchain layer and the egress allowlist. `blast-base` factors the
shared ~90% into one image. A consumer's `.devcontainer/` becomes roughly forty
lines: `FROM` the base, add a toolchain, declare an allowlist, mount volumes.

## Using it

```dockerfile
# .devcontainer/Dockerfile
ARG BLAST_BASE=ghcr.io/onideus/blast-base:0.1.0
FROM ${BLAST_BASE}

USER root
RUN apt-get update && apt-get install -y --no-install-recommends python3 \
    && apt-get clean && rm -rf /var/lib/apt/lists/*
USER node
```

Then copy `consumer/devcontainer.example.json` to `.devcontainer/devcontainer.json`
and set your allowlist. For a consumer that needs a database sidecar, start from
`consumer/devcontainer.compose.example.json` and
`consumer/docker-compose.example.yml` instead.

**Read [BLAST-CONTRACT.md](BLAST-CONTRACT.md).** It is the actual contract: what
you must supply, what you must not touch, and every `BLAST_*` variable.

## What is in the image

Node 22 (Debian slim), the Claude Code CLI, and exactly the packages
`init-firewall.sh` needs - `iptables`, `ipset`, `dnsutils`, `aggregate`, `jq`,
`curl`, `git`, and friends.

No language toolchain beyond Node. JDKs, Python, Godot and the rest are consumer
layers, deliberately.

`$BLAST_BASE_VERSION` inside the container reports which boundary you are on.

## Configuration

The firewall is byte-identical everywhere; configuration arrives through the
environment.

| Variable | Default |
|---|---|
| `BLAST_REQUIRED_DOMAINS` | *(empty)* - `api.anthropic.com registry.npmjs.org` always prepended |
| `BLAST_OPTIONAL_DOMAINS` | `sentry.io statsig.anthropic.com statsig.com` |
| `BLAST_ALLOW_GITHUB` | `true` |
| `BLAST_ALLOW_HOST_NETWORK` | `true` |

## Testing

Requires a moby/Docker engine that permits `--cap-add=NET_ADMIN`.

```
test/smoke.sh          # build, firewall assertions, idempotency, fail-closed
test/smoke-compose.sh  # sidecar-through-firewall proof
```

Both run in CI on every PR.

## Releasing

Tag `v*` and `publish.yml` builds and pushes
`ghcr.io/onideus/blast-base:{semver}`, `:{major.minor}`, and `:{sha}`.

**After the first publish, check the package is public.** It may already be.

Observed on the v0.1.0 publish: with `org.opencontainers.image.source` present
before the first publish and "Inherit access from source repository" enabled, the
package came out **public with no manual step**. GitHub's own documentation says a
newly published personal-scope package defaults to private and that a package
inherits a linked repository's access *permissions* but not its visibility - so
that outcome is more generous than the docs describe, and is not something to
lean on.

Treat it as verify-then-fix rather than a guaranteed manual step: look at
Package settings, and flip visibility only if it did not come out public.
Permission inheritance is the part the label reliably buys, and it only applies
if the link exists before the first publish.

The package needs to be public for a reason beyond convenience: blast containers
deliberately carry no credentials. If the base image were private, every consumer
would need registry credentials present at devcontainer build time - inside a
design whose whole point is that no credentials live there.

## License

MIT.
