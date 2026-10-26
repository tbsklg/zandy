# zandy

A macOS security sandbox wrapper for CLI coding agents. Launches a target binary inside a restricted seatbelt sandbox to limit filesystem and network access and reduce the risk of sensitive data exposure.

zandy builds a [Seatbelt (SBPL) profile](https://github.com/apple-oss-distributions/Sandbox) in memory, applies it to the current process via the `sandbox_init_with_parameters` libsandbox call, then `execve`s the target binary. Everything is denied by default; only the paths and services the target needs are granted, so locations like `~/.ssh`, `~/.aws`, Keychain and browser data are never reachable unless explicitly allowed via configuration.

zandy requires [Nix](https://nixos.org). A sandbox env is a Nix derivation built by `zandy.lib.mkSandboxEnv`: it decides which programs may run inside the sandbox, which adapters the broker offers, and the policy. There is no config file.

## Presets

| Preset | Binary | Notes |
|--------|--------|-------|
| `opencode` | `opencode` | Config/state/cache dirs under `~/.config`, `~/.local/share`, `~/.local/state`, `~/.cache` |
| `claude` | `claude` | `~/.claude` and `~/.claude.json` |

Both presets share a similar filesystem shape (working directory access, `/private/tmp`, `/private/var`) but grant access to the specific config/state paths each tool needs. Presets live in `nix/presets/`.

## Execution allowlist

Only programs from the sandbox env's Nix closure can run. For every store path in `<env>/store-paths` (and the env itself) the profile allows `process-exec` and `file-read*`; nothing else in `/nix/store`, nothing from `/opt/homebrew`, `/bin` or `/usr/bin`. The one exception is the `claude` preset, which may exec `/bin/sh` and `/bin/bash`: Claude Code runs `awsCredentialExport`, hooks and statusline commands with a hardcoded `/bin/sh`, and macOS's `/bin/sh` execs `/bin/bash`. A binary the agent copies or downloads into the working directory can't be executed either. `PATH` inside the sandbox is `<env>/sandbox/bin`, `SHELL` is its `bash`.

Scripts with a `#!/usr/bin/env …` shebang fail inside the sandbox, since `/usr/bin/env` isn't in the closure; run them with their interpreter (`bash ./script.sh`). Interpreters in the closure (bash, node, a JVM) can still run arbitrary code, so the allowlist is defense in depth; the broker remains the only path to secrets.

Network is the same for both: outbound TCP to port 443, the DNS socket `/private/var/run/mDNSResponder`, and the session's broker socket. Every other Unix socket (ssh-agent, Docker, …) and every other port is denied.

## Broker

zandy runs a broker next to the sandboxed agent. The agent can't use tools like `glab` directly — it has no token and can't read their config — but it can ask the broker, which runs the command outside the sandbox on its behalf.

```sh
zandy-client discover                                         # list methods as JSON
zandy-client call gitlab.cli '{"args":["issue","list","--repo","group/name"]}'  # run one, prints its stdout
```

The broker listens on a per-session Unix socket (`BROKER_SOCK`) and requires a per-session ticket (`BROKER_TICKET`); both are set in the agent's environment.

- **Policy:** by default only methods with effect `read` are offered and callable. Override per effect in `mkSandboxEnv`, e.g. to enable the passthrough methods (effect `admin`):

  ```nix
  policy.admin = "allow";
  ```

  `ask` behaves like `deny` until confirmation prompts exist.
- **Environment:** the sandboxed process only gets the variables its preset lists in `env` (for `claude` and `opencode`: `HOME`, `TMPDIR`, `USER`, `TERM`, `COLORTERM`, `LANG`, `LC_ALL`) plus `PATH`, `SHELL`, `BROKER_SOCK` and `BROKER_TICKET`. Secrets like `GITLAB_TOKEN` stay with the broker and only reach the adapter's command, together with `PATH` and `HOME`.
- **Arguments:** nothing goes through a shell. A `string` param fills exactly one argv entry and may not start with `-`. A `list` param (e.g. `aws.cli`'s `args`) expands into one entry per item, flags included. A `choice` param only accepts the values configured for it (e.g. `aws { profiles = [ … ]; }`); a capability whose choice has no values isn't offered.
- **Scope:** the broker doesn't decide which commands are safe. The passthrough methods can do whatever the credentials behind them can, so the scope is set outside zandy: the token's scopes for GitLab, the profile's IAM permissions for AWS.

### Adapters

An adapter is a Nix function from `pkgs` to an attrset; the bundled ones are in `nix/adapters/`. Projects can define their own the same way:

```nix
pkgs: {
  name = "gitlab";
  package = pkgs.glab;
  binary = "glab";
  env = [ "GITLAB_TOKEN" ];
  capabilities = [
    {
      name = "cli";
      description = "Run a glab command with the broker's GITLAB_TOKEN.";
      effect = "admin";
      params = [ { name = "args"; kind = "list"; description = "Arguments passed to glab"; } ];
      argv = [ "{args}" ];
    }
  ];
}
```

`env` lists variable **names** only; the values are read from zandy's environment at launch and never enter the Nix store. The broker runs `${package}/bin/${binary}` by its store path. An adapter's package must not be in `packages`: `mkSandboxEnv` fails the build if it is, and zandy refuses an env whose closure contains an adapter binary.

Bundled adapters:

| Method | Effect | Runs |
|--------|--------|------|
| `gitlab.cli` | `admin` | `glab {args}` with `GITLAB_TOKEN` |
| `aws.cli` | `admin` | `aws {args} --profile {profile}`, `profile` one of `aws { profiles = [ … ]; }` |

Both are deliberately broad: the agent gets the whole CLI, but never your token, `~/.aws` files or keys. The configured `--profile` is appended last, so it wins over any `--profile` in `args`. Specific methods (e.g. a fixed `issue list`) can be added as further capabilities.

### Model backend

With `backend.bedrock = { profile = "…"; region = "…"; }`, the agent's own model calls also go through the broker. zandy starts `claude` with `--settings` that enable Bedrock and set `awsCredentialExport` to `zandy-client call backend.credentials`. Claude Code runs that command itself at session start and before the credentials expire; the broker answers with `aws configure export-credentials --profile <profile>`. The profile should belong to an account that only hosts Bedrock: the agent can call `backend.credentials` too.

Keep `AWS_PROFILE` out of the `env` block of `~/.claude/settings.json`, otherwise claude tries to resolve it inside the sandbox. To use the same profile without zandy, set `"awsCredentialExport": "aws configure export-credentials --profile <profile> --format process"` there instead; zandy's `--settings` overrides it.

Methods are named `<adapter>.<capability>`. `{name}` in `argv` must be a whole entry and name a declared param; templates are parsed when the broker starts, so a bad one stops zandy before the agent runs.

### Telling the agent

The agent doesn't know about the broker on its own. Tell it, e.g.:

> For GitLab, don't run `glab`. Run `zandy-client discover` to see the available methods, then call one with `zandy-client call <method> '<json args>'`.

## Requirements

- macOS
- Nix with flakes

## Install

zandy isn't installed on its own: you install a sandbox env, which brings `zandy` and a launcher with it.

### Global (like a Homebrew install)

One env for all projects, e.g. in `~/.config/zandy`:

```sh
mkdir -p ~/.config/zandy && cd ~/.config/zandy
nix flake init -t git+https://codeberg.org/tbsklg/zandy
$EDITOR flake.nix                 # set backend.bedrock, adapters, policy
nix profile add ~/.config/zandy   # older Nix: nix profile install
```

The launcher is named after the env (`name = "claude"`), so this puts `zandy-claude` on your `PATH`:

```sh
cd ~/code/widgets
zandy-claude                      # start claude in the sandbox, in this directory
zandy-claude --resume             # arguments go to claude
```

After editing `flake.nix`, or to pick up a new zandy version: `nix flake update zandy && nix profile upgrade --all`. With home-manager, add the env to `home.packages` instead.

### Per project

To give the agent a project's toolchain (e.g. kotlin, gradle), put the env in the project's `flake.nix`, also starting from the template (`nix flake init -t …`), and add the tools to `packages`:

```nix
packages = [ pkgs.ripgrep pkgs.kotlin pkgs.gradle ];
filesystem.allowWrite = [ "~/.gradle" ];
```

```sh
nix run                           # start claude in the sandbox
nix run -- --resume               # arguments go to claude
```

### Without the launcher

The launcher is `zandy --env <env> "$@"`. To run zandy by hand:

```sh
nix build
nix shell git+https://codeberg.org/tbsklg/zandy#zandy
zandy --env ./result [args...]
zandy config --env ./result       # print the manifest and the methods the agent sees
```

`mkSandboxEnv` arguments:

- `preset`: `zandy.presets.claude` or `zandy.presets.opencode`. Brings its own packages (the agent, bash, coreutils, git) and `zandy-client`.
- `packages`: further programs the agent may run.
- `adapters`: what the broker offers; see [Adapters](#adapters).
- `policy`: `allow`, `ask` or `deny` per effect (`read`, `write`, `admin`).
- `backend`: `{ bedrock = { profile; region; }; }`. Required by the `claude` preset.
- `filesystem`: `allowRead`, `denyRead`, `allowWrite`, `denyWrite`, appended to the preset's profile. Paths may be absolute, `~`-relative, or relative to the working directory.

The env contains `bin/zandy-<name>` (the launcher), `sandbox/bin` (the sandbox `PATH`), `store-paths` (the execution allowlist) and `zandy.json` (the manifest zandy parses).

## Build from source

```sh
nix build .#zandy     # or: nix develop -c zig build
nix build             # the demo env (claude, placeholder backend)
```

## Architecture

- [`docs/architecture.puml`](docs/architecture.puml) — high-level component overview
- [`docs/runtime-flow.puml`](docs/runtime-flow.puml) — runtime sequence (env → sandbox → exec, broker calls)

Render the PNGs with `nix run nixpkgs#plantuml -- -tpng docs/*.puml`.

## Test

```sh
nix develop -c zig build test
```

Manual checks inside a running session: [`tests/test-default.md`](tests/test-default.md).

## Troubleshooting
- `glab` stores its token in `~/.config/glab-cli/config.yml` after `glab auth login`. The presets don't allow reading it; keep it that way, or the agent can bypass the broker.
- `opencode` does not start because of `operation not permitted mkdir '/var/folders/vg'`. The preset does not allow `opencode` to create a folder at that location. As a workaround start `opencode` without zandy first and then with zandy.
