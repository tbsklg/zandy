# Zandy Design

A macOS sandbox launcher with builtin profiles for well-known apps, inspired by OpenBSD's pledge().

## API

```
zandy <preset>                    # run with builtin profile
zandy -p "wpath" <preset>         # run with builtin profile + additional promises
zandy <preset> -- /explicit/path  # run with explicit binary path
```

## Concepts

### Presets

A preset is the minimum correct set of sandbox permissions an app needs to function.
Each preset is a `.zon` file under `src/profiles/` that is parsed at comptime via `@import`.

Presets are always required — there is no raw mode. Without a preset, the sandboxed process would crash or hang because the user can't know which mach lookups, IPC, or system operations an app requires.

### Promises (`-p`)

Additive user-defined capabilities on top of a preset. Coarse-grained named groups (inspired by pledge):

- `inet` — network access
- `rpath` — read filesystem paths
- `wpath` — write filesystem paths
- `fwrite` — file write/create

These extend the preset, they never replace it.

### Binary resolution

1. Check for explicit path after `--`
2. Otherwise search `PATH` environment variable ourselves (split on `:`, join with binary name, check executable exists)
3. No dependency on `/usr/bin/which`

## Preset lookup

Comptime lookup table mapping preset name to profile:

```zig
const presets = .{
    .{ .name = "opencode", .profile = @import("profiles/opencode.zon") },
    .{ .name = "claude", .profile = @import("profiles/claude.zon") },
};
```

At runtime, iterate and compare `.name` against the CLI argument.

## Examples

```
zandy opencode                     # sandbox opencode with its builtin profile
zandy claude                       # sandbox claude with its builtin profile
zandy -p "wpath" opencode          # opencode preset + extra write access
zandy opencode -- /usr/local/bin/opencode  # explicit binary path
```
