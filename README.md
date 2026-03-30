# zandy

A macOS security sandbox wrapper for [opencode](https://opencode.ai/). Launches `opencode` inside a restricted `sandbox-exec` environment to limit filesystem access and reduce the risk of sensitive data exposure.

## Profiles

| Profile | File access | Network |
|---------|-------------|---------|
| `default` | Broad read, restricted write; sensitive paths denied (`~/.ssh`, `~/.aws`, `~/.docker`, Keychain, browser data, shell history, etc.) | Allowed |
| `network_only` | Read-only; restricted to opencode config/cache dirs and CWD | Allowed |

## Requirements

- macOS (aarch64)
- `opencode` available in `PATH`

## Install

### Homebrew (recommended)

```sh
brew tap tbsklg/tap https://codeberg.org/tbsklg/homebrew-tap
brew install zandy
```

### Build from source

Requires [Zig](https://ziglang.org/) >= 0.15.2:

```sh
zig build
```

## Usage

```sh
zandy                        # default profile
zandy --profile network_only # network-only profile
```

## Configuration

Place a `.zandy.json` in the working directory (or `~/.config/zandy/config.json` for a global config):

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

## Scripts

Standalone shell scripts in `scripts/` — no Zig binary required, no config file support:

| Script | Profile |
|--------|---------|
| `scripts/opencode.sh` | `default` |
| `scripts/opencode-network-only.sh` | `network_only` |

## Test

```sh
zig build test
```
