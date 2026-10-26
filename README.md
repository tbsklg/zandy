# zandy

A macOS security sandbox wrapper for CLI coding agents. Launches a target binary inside a restricted seatbelt sandbox to limit filesystem and network access and reduce the risk of sensitive data exposure.

zandy builds a [Seatbelt (SBPL) profile](https://github.com/apple-oss-distributions/Sandbox) in memory, applies it to the current process via the `sandbox_init_with_parameters` libsandbox call, then `execve`s the target binary. Everything is denied by default; only the paths and services the target needs are granted, so locations like `~/.ssh`, `~/.aws`, Keychain and browser data are never reachable unless explicitly allowed via configuration.

## Presets

| Preset | Binary | Notes |
|--------|--------|-------|
| `opencode` | `opencode` | Config/state/cache dirs under `~/.config`, `~/.local/share`, `~/.local/state`, `~/.cache` |
| `claude` | `claude` | `~/.claude` and `~/.claude.json` |

Both presets share a similar filesystem shape (working directory access, `/private/tmp`, `/private/var`, homebrew) but grant access to the specific config/state paths each tool needs.

Network is the same for both: outbound TCP to port 443, the DNS socket `/private/var/run/mDNSResponder`, and the session's broker socket. Every other Unix socket (ssh-agent, Docker, …) and every other port is denied.

## Broker

zandy runs a broker next to the sandboxed agent. The agent can't use tools like `glab` directly — it has no token and can't read their config — but it can ask the broker, which runs the command outside the sandbox on its behalf.

```sh
zandy-client discover                                         # list methods as JSON
zandy-client call gitlab.cli '{"args":["issue","list","--repo","group/name"]}'  # run one, prints its stdout
```

The broker listens on a per-session Unix socket (`BROKER_SOCK`) and requires a per-session ticket (`BROKER_TICKET`); both are set in the agent's environment.

- **Policy:** by default only methods with effect `read` are offered and callable. Override per effect in `.zandy.json`, e.g. to enable the passthrough methods (effect `admin`):

  ```json
  { "policy": { "admin": "allow" } }
  ```

  `ask` behaves like `deny` until confirmation prompts exist.
- **Environment:** the sandboxed process only gets the variables its preset lists in `env` (for `claude` and `opencode`: `PATH`, `HOME`, `TMPDIR`, `USER`, `SHELL`, `TERM`, `COLORTERM`, `LANG`, `LC_ALL`) plus `BROKER_SOCK` and `BROKER_TICKET`. Secrets like `GITLAB_TOKEN` stay with the broker and only reach the adapter's command, together with `PATH` and `HOME`.
- **Arguments:** nothing goes through a shell. A `string` param fills exactly one argv entry and may not start with `-`. A `list` param (e.g. `aws.cli`'s `args`) expands into one entry per item, flags included. A `choice` param only accepts the values configured for it (see [Configuration](#configuration)); a capability whose choice has no configured values isn't offered.
- **Scope:** the broker doesn't decide which commands are safe. The passthrough methods can do whatever the credentials behind them can, so the scope is set outside zandy: the token's scopes for GitLab, the profile's IAM permissions for AWS.

### Adapters

An adapter is a `.zon` file in `src/adapters/` listed in `registry.bundled_adapters`:

```zig
.{
    .name = "gitlab",
    .binary = "glab",
    .env = .{"GITLAB_TOKEN"},
    .capabilities = .{
        .{
            .name = "cli",
            .description = "Run a glab command with the broker's GITLAB_TOKEN.",
            .effect = .admin,
            .params = .{
                .{ .name = "args", .kind = .list, .description = "Arguments passed to glab" },
            },
            .argv = .{"{args}"},
        },
    },
}
```

Bundled adapters:

| Method | Effect | Runs |
|--------|--------|------|
| `gitlab.cli` | `admin` | `glab {args}` with `GITLAB_TOKEN` |
| `aws.cli` | `admin` | `aws {args} --profile {profile}`, `profile` one of `adapters.aws.profile` |

Both are deliberately broad: the agent gets the whole CLI, but never your token, `~/.aws` files or keys. The configured `--profile` is appended last, so it wins over any `--profile` in `args`. Specific methods (e.g. a fixed `issue list`) can be added as further capabilities.

### Model backend

With a `bedrock` backend, the agent's own model calls also go through the broker. zandy starts `claude` with `--settings` that enable Bedrock and set `awsCredentialExport` to `zandy-client call backend.credentials`. Claude Code runs that command itself at session start and before the credentials expire; the broker answers with `aws configure export-credentials --profile <profile>`. The profile should belong to an account that only hosts Bedrock: the agent can call `backend.credentials` too.

Keep `AWS_PROFILE` out of the `env` block of `~/.claude/settings.json`, otherwise claude tries to resolve it inside the sandbox. To use the same profile without zandy, set `"awsCredentialExport": "aws configure export-credentials --profile <profile> --format process"` there instead; zandy's `--settings` overrides it.

Methods are named `<adapter>.<capability>`. `{name}` in `argv` must be a whole entry and name a declared param; templates are parsed when the broker starts, so a bad one stops zandy before the agent runs.

### Telling the agent

The agent doesn't know about the broker on its own. Tell it, e.g.:

> For GitLab, don't run `glab`. Run `zandy-client discover` to see the available methods, then call one with `zandy-client call <method> '<json args>'`.

## Requirements

- macOS
- The target binary (`opencode` or `claude`) available in `PATH`

## Install

### Homebrew (recommended)

```sh
brew tap tbsklg/tap https://codeberg.org/tbsklg/homebrew-tap
brew install zandy
```

### Build from source

Requires [Zig](https://ziglang.org/) >= 0.16.0 < 0.17.0:

```sh
zig build
```

The binaries are written to `zig-out/bin/zandy` and `zig-out/bin/zandy-client`. `zandy-client` must be on `PATH` and readable from inside the sandbox (e.g. under homebrew or the working directory).

## Usage

```sh
zandy opencode # sandbox opencode
zandy claude   # sandbox claude
zandy config   # print the effective config and the methods the agent sees
zandy --help
```

## Configuration

zandy reads `~/.config/zandy/config.json` and `.zandy.json` in the working directory and merges them key by key: a top-level key set in `.zandy.json` replaces the global one. `zandy config` shows the result.

```json
{
  "backend": { "bedrock": { "profile": "acme-bedrock", "region": "eu-west-1" } },
  "adapters": { "aws": { "profile": ["acme-dev", "acme-int"] } },
  "policy": { "admin": "allow" },
  "filesystem": {
    "allowRead": ["/some/extra/path"],
    "denyRead": [],
    "allowWrite": [],
    "denyWrite": []
  }
}
```

- `backend`: `{"anthropic": {}}` (default) or `{"bedrock": {"profile", "region"}}`.
- `adapters.<adapter>.<param>`: the allowed values of a `choice` param.
- `policy`: `allow`, `ask` or `deny` per effect.
- `filesystem`: rules appended to the active preset's profile. Paths may be absolute, `~`-relative, or relative to the working directory.

## Scripts

Standalone POSIX shell scripts in `scripts/` that wrap a tool with `sandbox-exec` directly — no Zig binary required, no config file support:

| Script | Wraps | Working directory access |
|--------|-------|--------------------------|
| `scripts/opencode.sh` | `opencode` | Full read/write |
| `scripts/opencode-network-only.sh` | `opencode` | Read-only |
| `scripts/claude.sh` | `claude` | Full read/write |

## Architecture

- [`docs/architecture.puml`](docs/architecture.puml) — high-level component overview
- [`docs/runtime-flow.puml`](docs/runtime-flow.puml) — runtime sequence (fork → sandbox → exec, broker calls)

## Test

```sh
zig build test
```

## Troubleshooting
- `glab` stores its token in `~/.config/glab-cli/config.yml` after `glab auth login`. The presets don't allow reading it; keep it that way, or the agent can bypass the broker.
- `opencode` does not start because of `operation not permitted mkdir '/var/folders/vg'`. The preset does not allow `opencode` to create a folder at that location. As a workaround start `opencode` without zandy first and then with zandy.
