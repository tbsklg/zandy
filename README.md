# zandy

A macOS security sandbox wrapper for [opencode](https://opencode.ai/). Launches `opencode` inside a restricted `sandbox-exec` environment to limit filesystem access and reduce the risk of sensitive data exposure.

## How it works

Uses macOS `sandbox-exec` with a least-privilege policy:

- **Network**: Outbound connections allowed (opencode needs to reach AI APIs)
- **File reads**: Broadly allowed, but denied for sensitive paths (`~/.ssh`, `~/.aws`, `~/.docker`, browser data, shell histories, Keychain, etc.)
- **File writes**: Restricted to the current working directory, opencode config/cache dirs, and temp locations

## Requirements

- macOS (aarch64)
- `opencode` available in `PATH`

## Install

### Homebrew (recommended)

```sh
brew tap tbsklg/zandy https://codeberg.org/tbsklg/homebrew-zandy
brew install zandy
```

### Build from source

Requires [Zig](https://ziglang.org/) >= 0.15.2:

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

## Script only

If you don't want to build the Zig binary, you can use `opencode.sh` directly. It applies the same sandbox policy without any configuration file support:

```sh
chmod +x opencode.sh
./opencode.sh
```

Or copy it somewhere on your `PATH`:

```sh
cp opencode.sh /usr/local/bin/zandy
```

Note: `opencode.sh` does not read `.zandy.json` or `~/.config/zandy/config.json`. For custom read/write allowlists, use the compiled binary.

## Test

Run the unit tests:

```sh
zig build test
```

Run the sandbox integration tests by passing `test-sandbox.md` as a file attachment:

```sh
./opencode.sh run "Run the tests and provide a summary." --file test-sandbox.md
```

The agent will execute each command in the table and report whether the results match the expected output.
