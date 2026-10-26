# TODO

## Vision: Nix-hooked sandbox

zandy requires Nix. Nix defines exactly which programs the sandboxed process and its children may run.

- [ ] `flake.nix`: `lib.mkSandboxEnv { name; packages; settings; }` builds one derivation per sandbox:
  - `bin/`: `buildEnv` of the allowed packages (claude-code, bash, git, ripgrep, zandy-client, …), the only `PATH` inside the sandbox
  - `store-paths`: the closure of `bin/`, one store path per line (`closureInfo`)
  - `settings.json`: claude config (backend, `awsCredentialExport`, permissions), read-only
- [ ] `zandy --env <drv> <preset>`: `--env` is required
- [ ] Parse `store-paths` into `[]const StorePath`; anything that isn't `/nix/store/<hash>-<name>` is a parse error
- [ ] Per store path: `(allow process-exec (subpath "<p>"))` and `(allow file-read* (subpath "<p>"))`; not all of `/nix/store`
- [ ] `PATH=<drv>/bin` in the sandbox env; binary from `<drv>/bin/<preset.binary>`; drop the host PATH search
- [ ] Profiles: drop the blanket `process_exec` allow and the `/opt/homebrew` rules
- [ ] Find out how claude loads the store `settings.json` (`claude --settings <file>`?)
- [ ] Wrapper packages `zandy-claude` / `zandy-opencode`
- [ ] Shell for claude's Bash tool: bash in the closure, `SHELL` set
- [ ] Check whether SBPL `process-exec` matches the symlink target

The broker stays the only path to secrets. The exec allowlist is defense in depth: interpreters in the closure can still do a lot.

## Ideas

- [ ] TUI to edit the config, built on `zandy config`. Has to agree with the Nix-generated config.
