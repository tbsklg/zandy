# zandy

A macOS sandbox for coding agents (Claude Code, opencode). The agent works in the current directory but can't read the rest of `$HOME`, can only run programs you declared in Nix, and never sees your credentials. Tools that need credentials (`glab`, `aws`) run outside the sandbox through a broker.

## Nix meets zandy

Nix builds the sandbox, zandy enforces it.

- **Nix** builds one env per sandbox from your `flake.nix`: the programs the agent may run, the adapters the broker offers, the policy.
- **zandy** reads that env, allows exactly those store paths to execute, sandboxes the agent and runs the broker.

So zandy only runs with Nix. Install it and enable flakes:

```sh
sh <(curl --proto '=https' --tlsv1.2 -L https://nixos.org/nix/install)
mkdir -p ~/.config/nix && echo "experimental-features = nix-command flakes" >> ~/.config/nix/nix.conf
```

Check with `nix flake --help`. zandy needs nothing else besides macOS; Zig, claude, glab and aws all come from Nix.

## Quickstart

```sh
mkdir -p ~/.config/zandy && cd ~/.config/zandy
nix flake init -t git+https://codeberg.org/tbsklg/zandy
$EDITOR flake.nix                 # set backend.bedrock and adapters
nix profile add ~/.config/zandy   # older Nix: nix profile install

cd ~/code/widgets
zandy-claude                      # claude, sandboxed, in this directory
```

After changing `flake.nix`: `nix flake update zandy && nix profile upgrade --all`.

For a project's own toolchain, put the same env in the project's `flake.nix`, add the tools to `packages` and start it with `nix run`.

## Configuration

```nix
zandy.lib.mkSandboxEnv {
  inherit pkgs;
  name = "claude";                                  # launcher: zandy-claude
  preset = zandy.presets.claude;                    # or zandy.presets.opencode
  packages = [ pkgs.ripgrep ];                      # extra programs the agent may run
  backend.bedrock = { profile = "acme-bedrock"; region = "eu-west-1"; };
  adapters = [
    zandy.adapters.gitlab                           # gitlab.cli, uses GITLAB_TOKEN
    (zandy.adapters.aws { profiles = [ "acme-dev" ]; })
  ];
  policy.admin = "allow";                           # default: only read methods
  filesystem.allowRead = [ "~/notes" ];
}
```

## What the agent can do

- Read and write the working directory, except `flake.nix`, `flake.lock`, `.envrc`, `.git/config` and `.git/hooks`.
- Run only programs from the env (`PATH` is the env's `sandbox/bin`). Homebrew, `/usr/bin` and downloaded binaries are blocked.
- Connect to port 443 and DNS. Nothing else.
- Use credentials only through the broker:

  ```sh
  zandy-client discover
  zandy-client call gitlab.cli '{"args":["issue","list","--repo","group/name"]}'
  ```

Details and design decisions: [design.md](design.md).

## Development

```sh
nix develop -c zig build test
```
