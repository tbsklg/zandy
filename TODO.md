# TODO

- **Fixed env vars for the sandbox.** A `sandboxEnv` option for non-secret values like `MAVEN_OPTS` or `npm_config_cache`, so toolchains that write to `~` work without project-side workarounds.
- **Show what the sandbox blocked.** Stream the Seatbelt log (`log stream --predicate 'sender == "Sandbox"'`) for the agent's process, so a denial names the operation and path instead of `Operation not permitted`.
- **Generic backend.** Backends under `nix/backends/` return `{ adapter; credential; env; }`; presets map the credential kind to their settings. An Anthropic-compatible backend (`baseUrl`, `keyEnv`) covers routers. Until then the claude preset only starts with Bedrock.
- **Project template.** `nix flake init -t zandy#project` for a flake in its own directory next to a project, sharing the toolchain with a devShell.
- **Check prerequisites at launch.** Warn when an adapter's env var (e.g. `GITLAB_TOKEN`) is unset, instead of failing on the first call.
- **Known issues.** Allow reading `~/.gitconfig` and `~/.config/git/config`; document `#!/usr/bin/env` shebangs.
