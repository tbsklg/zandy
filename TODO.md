# TODO

- **Fixed env vars for the sandbox.** A `sandboxEnv` option for non-secret values like `MAVEN_OPTS` or `npm_config_cache`, so toolchains that write to `~` work without project-side workarounds.
- **Project template.** `nix flake init -t zandy#project` for a flake in its own directory next to a project, sharing the toolchain with a devShell.
- **Narrow adapter methods.** Replace `gitlab.cli`'s free `args` with methods that can't print the token, e.g. no `config` or `auth` subcommands.
- **Refresh OAuth tokens.** `anthropicOauth` reads the token once at launch; a session can outlive it.
- **OpenAI in a preset.** No preset sets `gatewayEnv.openai` yet; opencode configures providers in its config file.
- **aws-sigv4-proxy 1.13.1.** Pinned to 1.13 until nixpkgs has Go 1.26.9.
- **Known issues.** Allow reading `~/.gitconfig` and `~/.config/git/config`; document `#!/usr/bin/env` shebangs.
