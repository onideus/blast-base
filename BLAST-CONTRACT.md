# The blast consumer contract

What a repo must supply to use `blast-base`, and what it must not touch.

## The contract in ten lines

1. `.devcontainer/Dockerfile` is `FROM ghcr.io/onideus/blast-base:<pinned tag>` plus your toolchain.
2. `.devcontainer/devcontainer.json` grants `NET_ADMIN` + `NET_RAW` and runs the firewall on `postStartCommand`.
3. The repo is bind-mounted at `/workspace`. Nothing else from the host is mounted.
4. Claude config and bash history live in named volumes, never on the host.
5. Egress is default-deny. You declare what you need in `BLAST_REQUIRED_DOMAINS`.
6. `api.anthropic.com` and `registry.npmjs.org` are always allowed and cannot be removed.
7. No credentials in any file - not the API key, not push credentials, not SSH keys.
8. `.devcontainer/` is human-review-only. Auto-mode work never edits it.
9. The base moves only by publishing a new tag and bumping the pin in a reviewed PR.
10. `*.sh text eol=lf` in `.gitattributes` is mandatory.

## Configuration

All of it arrives through the environment, so `init-firewall.sh` is byte-identical
in every consumer.

| Variable | Default | Behaviour |
|---|---|---|
| `BLAST_REQUIRED_DOMAINS` | *(empty)* | Space-separated. Abort if any is unresolvable. `api.anthropic.com registry.npmjs.org` are always prepended and cannot be removed - a consumer must not be able to lock Claude Code out of its own API. |
| `BLAST_OPTIONAL_DOMAINS` | `sentry.io statsig.anthropic.com statsig.com` | Space-separated. Warn and skip if unresolvable. |
| `BLAST_ALLOW_GITHUB` | `true` | Fetch the published GitHub IP ranges and allowlist them. `false` skips both the fetch and the `api.github.com` self-check, for a consumer that genuinely has no GitHub need. |
| `BLAST_ALLOW_HOST_NETWORK` | `true` | Allow the Docker gateway `/24`. This is the rule that lets the container reach a service on the host - a throwaway Postgres, say - and also the `/24` a compose sidecar sits on. |

Every domain token is validated against `^[A-Za-z0-9.-]+$` before use. An
environment variable is an injection surface; anything else aborts the run.

The effective configuration is logged at the top of every run, so you can read
the real boundary out of the `postStart` output instead of reconstructing it
from `devcontainer.json`.

> `BLAST_GITHUB_META_URL` also exists. It is a **test-harness seam only**, used by
> `test/smoke.sh` to point the meta fetch at a local stub and prove the
> fail-closed path. Never set it in a real consumer.

## Single-container mode

See `consumer/Dockerfile.example` and `consumer/devcontainer.example.json`.

`devcontainer.json` MUST carry:

- `runArgs`: `--cap-add=NET_ADMIN`, `--cap-add=NET_RAW`, `--add-host=host.docker.internal:host-gateway`
- `remoteUser: node`
- named volumes `<repo>-claude-config` to `/home/node/.claude` and `<repo>-bashhistory` to `/commandhistory`
- `workspaceMount` binding `${localWorkspaceFolder}` to `/workspace`
- `containerEnv` with `CLAUDE_CONFIG_DIR=/home/node/.claude` plus the `BLAST_*` variables
- `postCreateCommand: git config --global --add safe.directory /workspace` - bind mounts trip git's dubious-ownership check
- `postStartCommand: sudo /usr/local/bin/init-firewall.sh`
- `waitFor: postStartCommand` - so no session starts before the boundary is up

## Compose mode

For a consumer that needs a sidecar service brought up as part of devcontainer
init. See `consumer/devcontainer.compose.example.json` and
`consumer/docker-compose.example.yml`.

`devcontainer.json` uses `dockerComposeFile`, `service`, `workspaceFolder: /workspace`,
and `shutdownAction: stopCompose`. The compose file carries what `runArgs` would
have: `cap_add: [NET_ADMIN, NET_RAW]`, `extra_hosts`, the two named volumes, the
bind of `..` to `/workspace`, `command: sleep infinity`, the `BLAST_*` environment,
and `depends_on: {<sidecar>: {condition: service_healthy}}`.

Sidecars are declared in the **same compose file** - so they fall under the same
non-editable rule - use `tmpfs` for state, expose **no** host ports, and are
reached by service name.

Add the sidecar's service name to `BLAST_REQUIRED_DOMAINS`. This works because
`init-firewall.sh` preserves Docker's embedded DNS (`127.0.0.11`) nat rules across
the flush, `dig` resolves compose service names through it, and the resolved
container IP lands in the ipset like any other required domain. A name that fails
to resolve aborts the firewall, which is what you want: a container that refuses
to start beats a silently unreachable database.

`test/smoke-compose.sh` exists specifically to keep that path honest.

## The non-editable boundary

A consumer's `.devcontainer/` is human-review-only. Auto-mode work inside the
container never modifies it. The base image is not patched in place - it changes
only by publishing a new tag here and bumping the consumer's pin in a reviewed
PR. That is the whole reason the pin is a literal tag and never `:latest`.

Your toolchain layer may `USER root` to install packages, but must switch back to
`USER node` and must not touch the firewall script, the sudoers rule, or node's
ownership of `/workspace` and `/home/node/.claude`.

## Credentials

Never in any file. On first run inside the container, export the API key in the
shell and accept the trust dialog. Claude Code's config lives at
`~/.claude/.claude.json` inside the named volume - the root-level `~/.claude.json`
is ignored. Credentials die with:

```
docker volume rm <repo>-claude-config
```

No push credentials and no SSH keys live in a blast container. Outbound SSH
(port 22) is deliberately absent from the firewall for that reason: nothing in
here should be speaking it.

## Platform notes

**Windows.** Bind-mount I/O from the Windows filesystem is slow under WSL2. If
builds crawl, relocate the checkout into the WSL2 filesystem. `*.sh text eol=lf`
in `.gitattributes` is mandatory - CRLF endings produce
`bad interpreter: /bin/bash^M`.

**Host networking.** `BLAST_ALLOW_HOST_NETWORK=true` opens the Docker gateway
`/24`. On Docker Desktop and Rancher, `host.docker.internal` also reaches host
services bound to `127.0.0.1`. On a plain Linux engine it does **not** - the host
service must bind `0.0.0.0` or the bridge IP. Knowing this saves you chasing a
phantom firewall bug.
