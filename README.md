# zandy

A macOS security sandbox wrapper for CLI coding agents. Launches a target binary inside a restricted seatbelt sandbox to limit filesystem and network access and reduce the risk of sensitive data exposure.

zandy builds a [Seatbelt (SBPL) profile](https://github.com/apple-oss-distributions/Sandbox) in memory, applies it to the current process via the `sandbox_init_with_parameters` libsandbox call, then `execve`s the target binary. Everything is denied by default; only the paths and services the target needs are granted, so locations like `~/.ssh`, `~/.aws`, Keychain and browser data are never reachable unless explicitly allowed via configuration.

## Presets

| Preset | Binary | Notes |
|--------|--------|-------|
| `opencode` | `opencode` | Outbound network only; config/state/cache dirs under `~/.config`, `~/.local/share`, `~/.local/state`, `~/.cache` |
| `claude` | `claude` | Outbound network only; `~/.claude` and `~/.claude.json` |

Both presets share a similar filesystem shape (working directory access, `/private/tmp`, `/private/var`, homebrew) but grant access to the specific config/state paths each tool needs.

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

The binary is written to `zig-out/bin/zandy`.

## Usage

```sh
zandy opencode # sandbox opencode
zandy claude   # sandbox claude
zandy --help
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

These rules are appended to the active preset's profile.

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
