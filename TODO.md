# TODO

## Nix-hooked sandbox

zandy requires Nix. Nix defines exactly which programs the sandboxed process and its children may run.

- [x] `lib.mkSandboxEnv { pkgs; name; preset; packages; adapters; policy; backend; filesystem; }`: `sandbox/bin`, `store-paths`, `zandy.json`, launcher `bin/zandy-<name>`
- [x] `zandy --env <drv>`: `--env` is required, parsed as a `StorePath`
- [x] Parse `store-paths` into `[]const StorePath`
- [x] Per store path: `(allow process-exec (subpath "<p>"))` and `(allow file-read* (subpath "<p>"))`
- [x] `PATH=<drv>/sandbox/bin`, `SHELL=<drv>/sandbox/bin/bash`, binary from `<drv>/sandbox/bin/<binary>`; no host `PATH` search
- [x] Profiles: no blanket `process-exec`, no `/opt/homebrew`
- [x] Presets, adapters, policy, backend, filesystem in Nix; `.zandy.json` and `~/.config/zandy` removed
- [x] Adapter packages are never in the sandbox closure (Nix assert + `SandboxEnv.parse`)
- [x] `process-exec` through the `sandbox/bin` symlinks works (both the env and the targets are allowed)
- [x] Bedrock backend: claude spawns `awsCredentialExport` via a hardcoded `/bin/sh`; the claude preset allows exec of `/bin/sh` and `/bin/bash` only
- [ ] `#!/usr/bin/env` shebangs fail inside the sandbox. Allow `/usr/bin/env`, or ship an `env` at that path some other way?
- [ ] Run the opencode preset for real (`pkgs.opencode`)
- [ ] Update `docs/*.puml` for the Nix flow
- [ ] Broker side still inherits the host `PATH` for adapter commands (e.g. `aws` credential helpers); decide whether to narrow it

The broker stays the only path to secrets. The exec allowlist is defense in depth: interpreters in the closure can still do a lot.
