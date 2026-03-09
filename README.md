# zandy

A macOS security sandbox wrapper for [opencode](https://opencode.ai/). It launches `opencode` inside a restricted `sandbox-exec` environment to limit filesystem access and reduce the risk of sensitive data exposure.

## How it works

`zandy` uses the macOS `sandbox-exec` utility with a custom sandbox profile (`opencode.sb`) that enforces a least-privilege policy:

- **Network**: All outbound connections are allowed (opencode needs to reach AI APIs)
- **File reads**: Broadly allowed, but denied for sensitive locations such as `~/.ssh`, `~/.aws`, `~/.docker`, browser data, shell histories, macOS Keychain, and personal folders
- **File writes**: Restricted to the current working directory, opencode config/cache directories, and temp locations

## Requirements

- macOS
- [Zig](https://ziglang.org/) >= 0.15.2
- `opencode` installed at `/opt/homebrew/bin/opencode`

## Build

```sh
zig build
```

The binary is output to `zig-out/bin/zandy`.

## Usage

Run from the directory you want opencode to work in:

```sh
zandy
# or
zig build run
```

## Test

```sh
zig build test
```
