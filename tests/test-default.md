# Manual Sandbox Tests

Start a session with `zandy-claude` (or `nix run` in a project with a zandy env), then verify each scenario from inside the agent, e.g. with its Bash tool.

The profile is **deny-default**: the working directory is read+write, the env's Nix closure is read+exec, network is outbound TCP to `*:443`, DNS and the broker socket. Everything else is denied because it is never allowed.

## Execution allowlist

| Scenario | Expected |
|---|---|
| `command -v rg git bash` | Paths under `<env>/sandbox/bin` |
| `echo $PATH` | Only `<env>/sandbox/bin` |
| Run `/opt/homebrew/bin/brew --version` | Operation not permitted |
| Run `/bin/ls` or `/usr/bin/security` | Operation not permitted |
| Run a store path outside the closure, e.g. another `/nix/store/…/bin/…` | Operation not permitted |
| Read a file of a store path outside the closure | Operation not permitted |
| Copy `rg` into CWD and run the copy | Operation not permitted |
| `command -v glab aws` | Not found (adapters run in the broker only) |
| Run `/bin/sh -c 'echo ok'` (claude preset only) | `ok` |

## Broker

| Scenario | Expected |
|---|---|
| `zandy-client discover` | Lists the methods allowed by the env's policy |
| `zandy-client call aws.cli '{"profile":"<configured>","args":["--version"]}'` | aws version |
| Same with a profile that isn't configured | `Invalid params`, exit code 4 |
| `zandy-client call backend.credentials` | JSON credentials (Bedrock env only) |
| `env \| grep -i -E 'token\|secret\|aws_'` | Nothing |

## Read restrictions (credentials and personal data)

| Scenario | Expected |
|---|---|
| Read `~/.ssh/id_rsa` | Operation not permitted |
| Read `~/.aws/credentials` or `~/.aws/config` | Operation not permitted |
| Read `~/.config/glab-cli/config.yml` | Operation not permitted |
| Read `~/.docker/config.json` | Operation not permitted |
| Read `~/.netrc` | Operation not permitted |
| Read `~/.git-credentials` | Operation not permitted |
| Read `~/.kube/config` | Operation not permitted |
| Read `~/.npmrc` | Operation not permitted |
| Read `~/.env` | Operation not permitted |
| Read `~/.envrc` | Operation not permitted |
| Read `~/.zsh_history` | Operation not permitted |
| List `~/Desktop` | Operation not permitted |
| List `~/Documents` | Operation not permitted |
| List `~/Downloads` | Operation not permitted |
| List `~/Library/Keychains` | Operation not permitted |
| List `~/Library/Safari` | Operation not permitted |
| List `~/Library/Mail` | Operation not permitted |
| List `~/Library/Messages` | Operation not permitted |

## Rename/move bypass

| Scenario | Expected |
|---|---|
| Move `~/.ssh` to `/tmp/` | Operation not permitted |
| Move `~/.aws/credentials` to `/tmp/` | Operation not permitted |
| Move `~/.netrc` to `/tmp/` | Operation not permitted |

## Process restrictions

| Scenario | Expected |
|---|---|
| List all system processes | Operation not permitted or empty |
| Send a signal to PID 1 | Operation not permitted |

## Write restrictions (outside CWD)

| Scenario | Expected |
|---|---|
| Create a file in `$HOME` (outside CWD) | Operation not permitted |
| Write `~/.claude/settings.json` | Operation not permitted |
| Write to `/dev/null` | Success (explicitly allowed) |

## Network

| Scenario | Expected |
|---|---|
| HTTPS request to a public host (port 443) | Succeeds |
| TCP connection to port 80 or 22 | Operation not permitted |
| Connect to `$SSH_AUTH_SOCK` or the Docker socket | Operation not permitted |
| Resolve a public DNS name | Returns an IP address |

## Normal operation

| Scenario | Expected |
|---|---|
| Run a shell built-in | Produces expected output |
| Read a file in CWD | File contents displayed |
| Create and delete a file in CWD | No error |
| Create a file in `/tmp` | No error |
| `git status` in CWD | Works |
| Run a script with `bash ./script.sh` | Works |
| Run a script with a `#!/usr/bin/env bash` shebang | Operation not permitted (known, see TODO.md) |
