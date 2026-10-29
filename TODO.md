# TODO

- **Fixed env vars for the sandbox.** A `sandboxEnv` option for non-secret values like `MAVEN_OPTS` or `npm_config_cache`, so toolchains that write to `~` work without project-side workarounds.
- **Show what the sandbox blocked.** Stream the Seatbelt log (`log stream --predicate 'sender == "Sandbox"'`) for the agent's process, so a denial names the operation and path instead of `Operation not permitted`.
- **Project template.** `nix flake init -t zandy#project` for a flake in its own directory next to a project, sharing the toolchain with a devShell.
- **Check prerequisites at launch.** Warn when an adapter's env var (e.g. `GITLAB_TOKEN`) or the gateway's key (e.g. `ANTHROPIC_API_KEY`) is unset, instead of failing on the first call.
- **Debug log.** `ZANDY_LOG=debug` writes broker and gateway traces to `~/.zandy/log/<pid>.log`, metadata only; the gateway proxy's stderr goes there too instead of the terminal.
- **OpenAI in a preset.** No preset sets `gatewayEnv.openai` yet; opencode configures providers in its config file.
- **aws-sigv4-proxy 1.13.1.** Pinned to 1.13 until nixpkgs has Go 1.26.9.
- **Known issues.** Allow reading `~/.gitconfig` and `~/.config/git/config`; document `#!/usr/bin/env` shebangs.
