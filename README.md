# zandy

A declarative macOS sandbox for coding agents, built with Nix.

Coding agents like Claude Code and opencode run with your user's permissions: read access to all of `$HOME`, every program on the system and every credential. zandy restricts the process to what you declare in a flake:

- **Files:** the project directory, not the rest of `$HOME`.
- **Programs:** only those in the env; nothing from Homebrew or `/usr/bin`.
- **Credentials:** none. Tools that need them, like `glab` and `aws`, run outside the sandbox through a broker.

## Vision

zandy is a proof of concept. The goal is a self-contained, declarative sandbox that follows functional patterns:

- **A pure function of its declaration.** One flake describes everything an agent gets: tools, filesystem, network, credentials and the model backend. The same flake always yields the same sandbox; nothing outside it, no global config or state in `$HOME`, changes the result.
- **Immutable.** The built sandbox is a read-only value in `/nix/store`. Changing it means changing the declaration and building a new one, not mutating the old one.
- **Side effects at the edge.** The sandbox holds no credentials. Effects that need them happen outside, in the broker, through explicit requests.
- **Parse, don't validate.** Every input is parsed into a precise type, once, at the boundary: the flake by the Nix options, the manifest and requests by zandy.

Next steps are in [TODO.md](TODO.md).

## Nix in 30 seconds

Nix is a package manager that builds every package into its own read-only directory under `/nix/store`, named by a hash of everything that went into it (`/nix/store/…-ripgrep-14.1.1`). A package's *closure* is that directory plus every store path it depends on. A `flake.nix` describes what to build and pins all inputs in `flake.lock`, so the same flake builds the same result on any machine.

## Why Nix

- **An exact list of what may run.** The closure is every file the agent's tools need. zandy allows exactly those store paths to execute, instead of allowing all of `/usr/bin` or Homebrew.
- **Tools the agent can't change.** `/nix/store` is read-only, so the agent can't modify or replace the programs it runs.
- **Per-project toolchains.** A project's JDK or Node version lives in its env, not installed globally.
- **Typed configuration.** Your sandbox is a Nix expression, checked at build time. zandy has no config files of its own.
- **Reproducible.** Pinned inputs mean the same sandbox for everyone on the team.

## How it fits together

![overview](docs/overview.png)

- **Nix describes the sandbox:** which tools live inside, which stay outside behind the broker. The result holds no secrets.
- **zandy** (Zig) turns that into a Seatbelt profile, starts the agent and runs the broker, which brings in credentials outside the sandbox.
- **Seatbelt**, the macOS kernel sandbox, enforces the profile.

Install Nix and enable flakes:

```sh
sh <(curl --proto '=https' --tlsv1.2 -L https://nixos.org/nix/install)
mkdir -p ~/.config/nix && echo "experimental-features = nix-command flakes" >> ~/.config/nix/nix.conf
```

Check with `nix flake --help`. zandy needs nothing else besides macOS; Zig, claude, glab and aws all come from Nix.

## Quickstart

You need:

- An AWS profile with Bedrock access in `~/.aws/config`, logged in (e.g. `aws sso login --profile acme-bedrock`). The claude preset runs Claude Code through Bedrock.
- The env vars of the adapters you keep, exported in the shell that starts zandy, e.g. `GITLAB_TOKEN` for `zandy.adapters.gitlab`.

```sh
mkdir -p ~/.config/zandy && cd ~/.config/zandy
nix flake init -t git+https://codeberg.org/tbsklg/zandy
$EDITOR flake.nix                 # replace the acme-* profiles, drop adapters you don't need
git init && git add -A            # flakes only see files git tracks
nix profile add ~/.config/zandy   # older Nix: nix profile install

cd ~/code/widgets
zandy-claude                      # claude, sandboxed, in this directory
zandy-claude --zandy-config       # the manifest and the broker methods, without starting claude
```

After changing `flake.nix`: `git add -A && nix flake update zandy && nix profile upgrade --all`.

### Per project

For a project's own toolchain, give it its own env and add the tools to `packages`. Keep the flake in its own directory outside the project, so it needn't be committed and the agent can't edit it, and start it from the project root:

```sh
cd ~/code/widgets
nix run ~/.config/zandy/widgets
```

## Configuration

```nix
zandy.lib.mkSandboxEnv {
  inherit pkgs;
  name = "claude";                                  # launcher: zandy-claude
  preset = zandy.presets.claude;                    # or zandy.presets.opencode
  packages = [ pkgs.ripgrep ];                      # extra programs the agent may run
  gateway = zandy.gateways.bedrock { profile = "acme-bedrock"; region = "eu-west-1"; };
  adapters = [
    zandy.adapters.gitlab                           # gitlab.cli, uses GITLAB_TOKEN
    (zandy.adapters.aws { profiles = [ "acme-dev" ]; })
  ];
  filesystem.allowRead = [ "~/notes" ];
}
```

| Option | What it sets |
|---|---|
| `name` | The env's name; the launcher becomes `zandy-<name>` |
| `preset` | The app to run and the sandbox rules it needs |
| `packages` | Extra programs on the agent's `PATH` |
| `gateway` | The model backend the agent reaches through the broker: `zandy.gateways.bedrock`, `.anthropic` or `.openai`; its credentials stay outside the sandbox |
| `adapters` | Tools the broker runs outside the sandbox; listing one makes it callable |
| `filesystem` | Extra paths to allow or deny for reading and writing |

Unknown or mistyped options fail at build time. Full reference with types and defaults: [docs/options.md](docs/options.md), generated with `nix build .#options-doc`.

## Write your own adapter

An adapter is a function from `pkgs` to an attrset; `zandy.adapters.gitlab` is one ([nix/adapters/gitlab.nix](nix/adapters/gitlab.nix)). Define your own in your flake and add it to `adapters`. This one runs macOS text-to-speech, which the sandbox can't reach:

```nix
let
  say = pkgs: {
    name = "mac";
    package = pkgs.writeShellScriptBin "say" ''exec /usr/bin/say -v "$1" "$2"'';
    binary = "say";
    capabilities = [
      {
        name = "say";
        description = "Speak a text out loud on the user's Mac.";
        params = [
          { name = "voice"; kind = "choice"; choices = [ "Bad News" "Good News" "Cellos" "Zarvox" ]; description = "Voice to speak with"; }
          { name = "text"; description = "Text to speak"; }
        ];
        argv = [ "{voice}" "{text}" ];
      }
    ];
  };
in
zandy.lib.mkSandboxEnv {
  # …
  adapters = [ say ];
}
```

The agent then calls `zandy-client call mac.say '{"voice":"Bad News","text":"the tests failed"}'`. `say` is not a Nix package, so a one-line wrapper calls `/usr/bin/say`; it runs in the broker, where `/usr/bin` is reachable. A real adapter adds the env vars that hold its secrets, e.g. `env = [ "GITLAB_TOKEN" ];`.

| Field | Meaning |
|---|---|
| `name` | Prefix of the method names: `<name>.<capability>` |
| `package` | Derivation the broker runs; must not be in `packages` or the preset's packages |
| `binary` | Program in `package/bin` |
| `env` | Env vars passed from the shell that started zandy, besides `PATH` and `HOME` |
| `capabilities` | The methods: `name`, `description`, `params`, `argv` |

How the broker runs a method:

- **argv.** Each element is a literal or a whole `{param}`; `"--repo={param}"` is not substituted. A `list` param expands to several arguments.
- **Params.** All are required. `string` and `choice` values may not start with `-`, so they can't become options. A `choice` with an empty `choices` list drops the method. `list` values pass through unchecked.
- **Process.** The command runs outside the sandbox, in the directory zandy started in. Exit 0 returns stdout to the agent; anything else returns stderr.

Whatever the command can do, the agent can do. Prefer narrow methods with `string` and `choice` params over a `list` that passes arguments through: `git` with free arguments runs any command, e.g. via `-c core.sshCommand=…`. Avoid tools that read the project directory, like `git` or `make`: the agent can write there, and the command runs what the project configures, outside the sandbox.

## What the agent can do

- Read and write the working directory, except `flake.nix`, `flake.lock`, `.envrc`, `.git/config` and `.git/hooks`.
- Run only programs from the env (`PATH` is the env's `sandbox/bin`). Homebrew, `/usr/bin` and downloaded binaries are blocked.
- Connect to port 443 and DNS. Nothing else.
- Use credentials only through the broker:

  ```sh
  zandy-client discover
  zandy-client call gitlab.cli '{"args":["issue","list","--repo","group/name"]}'
  ```

  Adapters pass commands through; the token's scopes and the profile's IAM permissions decide what they may do.

Details and design decisions: [design.md](design.md).

## Development

```sh
nix develop -c zig build test
```
