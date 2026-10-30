# zandy

**A sandbox for coding agents on macOS: declared in Nix, run by Zig, enforced by the macOS kernel.**

You declare in a flake what Claude Code or opencode may touch. zandy starts the agent so it can't touch anything else:

- your project, not the rest of `$HOME`
- your flake's tools, not your machine's
- port 443 and the model gateway, nothing else
- no credentials inside the sandbox

## How it works

**Nix** declares the sandbox: tools, files, network, adapters and the model backend. **zandy**, written in Zig, turns that into a Seatbelt profile, then starts the agent with a broker and a gateway that use your credentials outside the sandbox. **Seatbelt**, the macOS kernel sandbox, enforces the profile, and the agent can't loosen it.

The same flake always gives the same sandbox, the built sandbox is read-only, and it holds no secrets.

Apple Silicon only.

## Quickstart

With [Nix](https://nixos.org/download) and flakes enabled:

```sh
mkdir -p ~/.config/zandy && cd ~/.config/zandy
nix flake init -t git+https://codeberg.org/tbsklg/zandy
$EDITOR flake.nix
git init && git add -A
nix profile add ~/.config/zandy
```

Then start the agent in any project:

```sh
cd ~/code/widgets
zandy-claude
```

The template uses Bedrock and the GitLab and AWS adapters. To switch the model backend or set up secrets, see the [docs](docs/README.md).

## Update

After editing your flake:

```sh
nix profile upgrade --all
```

To also pull the latest zandy, run in the flake's directory:

```sh
nix flake update zandy && nix profile upgrade --all
```

If your flake is in a git repo, `git add` new files first. Flakes only see tracked files.

## Documentation

Everything else is in [docs](docs/README.md): configuration, model backends, secrets, writing adapters, security limits and troubleshooting.
