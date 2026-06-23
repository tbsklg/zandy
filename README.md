# zandy

A macOS security sandbox wrapper for [opencode](https://opencode.ai/). Launches `opencode` inside a restricted seatbelt sandbox to limit filesystem access and reduce the risk of sensitive data exposure.

zandy builds a [Seatbelt (SBPL) profile](https://github.com/apple-oss-distributions/Sandbox) in memory, applies it to the current process via the `sandbox_init_with_parameters` libsandbox call, then `execve`s `opencode`. Everything is denied by default; only the paths and services opencode needs are granted, so locations like `~/.ssh`, `~/.aws`, Keychain and browser data are never reachable.

## Profiles

| Profile | Working directory | Other filesystem | Network |
|---------|-------------------|------------------|---------|
| `default` | Full read/write (`file*`) | opencode config/state/cache dirs read/write; system paths needed to run; everything else denied | Allowed |
| `network_only` | Read-only (`file-read*`) | same as `default` | Allowed |

Both profiles share the same base ruleset; they differ only in the level of access granted to the working directory.

## Requirements

- macOS
- `opencode` available in `PATH`

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

The binary is written to `zig-out/bin/zandy`.

## Usage

```sh
zandy                        # default profile
zandy --profile network_only # network-only profile
zandy --profile=network_only # equivalent
```

## Configuration

Place a `.zandy.json` in the working directory, or `~/.config/zandy/config.json` for a global config (the local file takes precedence). Paths may be absolute, `~`-relative, or relative to the working directory:

```json
{
  "filesystem": {
    "allowRead": ["/some/extra/path"],
    "denyRead": [],
    "allowWrite": [],
    "denyWrite": []
  }
}
```

These rules are appended to the active profile.

## Scripts

Standalone POSIX shell scripts in `scripts/` that wrap a tool with `sandbox-exec` directly — no Zig binary required, no config file support:

| Script | Wraps | Working directory access |
|--------|-------|--------------------------|
| `scripts/opencode.sh` | `opencode` | Full read/write |
| `scripts/opencode-network-only.sh` | `opencode` | Read-only |
| `scripts/claude.sh` | `claude` | Full read/write |

## Architecture

- [`docs/architecture.puml`](docs/architecture.puml) — high-level component overview
- [`docs/runtime-flow.puml`](docs/runtime-flow.puml) — runtime sequence (fork → sandbox → exec)

## Test

```sh
zig build test
```
