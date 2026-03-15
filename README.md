# zandy

A macOS security sandbox wrapper for [opencode](https://opencode.ai/). Launches `opencode` inside a restricted `sandbox-exec` environment to limit filesystem access and reduce the risk of sensitive data exposure.

## How it works

Uses macOS `sandbox-exec` with a least-privilege policy:

- **Network**: Outbound connections allowed (opencode needs to reach AI APIs)
- **File reads**: Broadly allowed, but denied for sensitive paths (`~/.ssh`, `~/.aws`, `~/.docker`, browser data, shell histories, Keychain, etc.)
- **File writes**: Restricted to the current working directory, opencode config/cache dirs, and temp locations

## Requirements

- macOS
- [Zig](https://ziglang.org/) >= 0.15.2
- `opencode` available in `PATH`

## Install

```sh
zig build
```

## Usage

Run from the directory you want opencode to work in:

```sh
zandy
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

## Test

```sh
zig build test
```
