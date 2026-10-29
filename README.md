# zandy

**A sandbox for coding agents on macOS: declared in Nix, run by Zig, enforced by the macOS kernel.**

You declare in a flake what Claude Code or opencode may touch, and zandy starts the agent so it can't touch anything else:

- your project, not the rest of `$HOME`
- your flake's tools, not your machine's
- port 443 and the gateway, nothing else
- no credentials inside: the broker and the gateway use them outside the sandbox

| | |
|---|---|
| **Nix** | declares the sandbox: tools, files, network, adapters, model backend |
| **Zig** | zandy itself: builds the Seatbelt profile, reads the secrets, runs the broker and the gateway |
| **macOS** | Seatbelt enforces the profile in the kernel; secrets live in the keychain. Apple Silicon only |

The design follows three principles: the sandbox is a pure function of its declaration, it is immutable, and it holds no credentials. See [design.md](design.md#principles).

## Quickstart

Install Nix and enable flakes; Zig, claude, glab, aws and the gateway proxies all come from Nix:

```sh
sh <(curl --proto '=https' --tlsv1.2 -L https://nixos.org/nix/install)
mkdir -p ~/.config/nix && echo "experimental-features = nix-command flakes" >> ~/.config/nix/nix.conf
```

You also need:

- A model backend for the gateway: an AWS profile with Bedrock access in `~/.aws/config`, logged in (e.g. `aws sso login --profile acme-bedrock`), or an Anthropic API key. See [Model backend](#model-backend).
- The secrets of the adapters you keep, e.g. a GitLab token for `zandy.adapters.gitlab`. See [Secrets](#secrets).

```sh
mkdir -p ~/.config/zandy && cd ~/.config/zandy
nix flake init -t git+https://codeberg.org/tbsklg/zandy
$EDITOR flake.nix                 # replace the acme-* profiles, drop adapters you don't need
git init && git add -A            # flakes only see files git tracks
nix profile add ~/.config/zandy   # older Nix: nix profile install

cd ~/code/widgets
zandy-claude                      # claude, sandboxed, in this directory
zandy-claude --zandy-config       # the manifest and the broker methods, without starting claude
zandy-claude --zandy-secret gitlab-token   # store a secret, see Secrets
```

After changing `flake.nix`: `git add -A && nix flake update zandy && nix profile upgrade --all`.

### Per project

For a project's own toolchain, give it its own env and add the tools to `packages`. Keep the flake in its own directory outside the project, so it needn't be committed and the agent can't edit it, and start it from the project root:

```sh
cd ~/code/widgets
nix run ~/.config/zandy/widgets
```

## How it works

```
 build time                     run time

 flake.nix                      zandy.keychain-db
    │                               │ secrets
    ▼                               ▼
   Nix ──▶ sandbox env ──────▶   zandy ─────────── profile ──────────┐
           tools, manifest,         │ starts, hands secrets           ▼
           no secrets               │ via named pipes        ┌─ Seatbelt ──┐
                          ┌─────────┴────────┐               │    agent    │
                          ▼                  ▼               └──┬───────┬──┘
                       broker ◀── request ───┼──────────────────┘       │
                       runs glab, aws        │                          │
                          │               gateway ◀──────── HTTP ───────┘
                          ▼               proxy, adds auth
                     GitLab, AWS             │ HTTPS
                                             ▼
                                        model backend
```

- **Nix describes the sandbox:** which tools live inside, which stay outside behind the broker. The result holds no secrets.
- **zandy** (Zig) turns that into a Seatbelt profile, reads the secrets, starts the gateway and the agent, and runs the broker.
- **Seatbelt** enforces the profile. Once applied, the agent can't loosen it.

The agent may write the project directory, except `flake.nix`, `flake.lock`, `.envrc`, `.git/config` and `.git/hooks`. It may run only programs from the env's closure, so no Homebrew, `/usr/bin` or binaries it downloads, and connect only to port 443, DNS and the gateway's port on localhost.

Inside the sandbox, the agent reaches your tools through the broker:

```sh
zandy-client discover
zandy-client call gitlab.cli '{"args":["issue","list","--repo","group/name"]}'
```

Adapters pass commands through; the token's scopes and the profile's IAM permissions decide what they may do. Design decisions: [design.md](design.md). Next steps: [TODO.md](TODO.md).

## Configuration

```nix
zandy.lib.mkSandboxEnv {
  inherit pkgs;
  name = "claude";                                  # launcher: zandy-claude
  preset = zandy.presets.claude;                    # or zandy.presets.opencode
  packages = [ pkgs.ripgrep ];                      # extra programs the agent may run
  gateway = zandy.gateways.bedrock { profile = "acme-bedrock"; region = "eu-west-1"; };
  adapters = [
    (zandy.adapters.gitlab { })                     # gitlab.cli, uses the gitlab-token secret
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
| `gateway` | The model backend, reached through a local proxy outside the sandbox: `zandy.gateways.bedrock`, `.anthropic` or `.openai`; its credentials stay outside |
| `adapters` | Tools the broker runs outside the sandbox; listing one makes it callable |
| `filesystem` | Extra paths to allow or deny for reading and writing |

Unknown or mistyped options fail at build time. Full reference with types and defaults: [docs/options.md](docs/options.md), generated with `nix build .#options-doc`.

## Model backend

The agent reaches its model through a gateway: a local proxy zandy starts outside the sandbox, which adds the credentials and forwards to one fixed upstream. The sandbox can only reach the gateway's port; the key never enters it.

| Gateway | Proxy | Needs |
|---|---|---|
| `zandy.gateways.bedrock { profile; region; }` | `aws-sigv4-proxy`, signs with the profile | a logged-in AWS profile |
| `zandy.gateways.anthropic { service ? "anthropic-api-key"; }` | Caddy, sets `X-Api-Key` | the API key, stored with `--zandy-secret anthropic-api-key` |
| `zandy.gateways.anthropicOauth { }` | Caddy, sets `Authorization: Bearer` with the Claude subscription login it reads from the login keychain at start | a Claude login, from running `claude` once outside zandy |
| `zandy.gateways.openai { service ? "openai-api-key"; host ? "api.openai.com"; }` | Caddy, sets `Authorization: Bearer` | the API key, stored with `--zandy-secret openai-api-key` |

The preset decides how the app finds the gateway, via `gatewayEnv`. The claude preset sets `ANTHROPIC_BEDROCK_BASE_URL` and `CLAUDE_CODE_SKIP_BEDROCK_AUTH` for Bedrock, and `ANTHROPIC_BASE_URL` for Anthropic. One gateway at a time; without one, the app reaches no model through zandy.

## Secrets

zandy keeps secrets in its own keychain, `~/.zandy/zandy.keychain-db`, outside the sandbox. Create it once; `security` asks for a password for it:

```sh
security create-keychain ~/.zandy/zandy.keychain-db
security set-keychain-settings ~/.zandy/zandy.keychain-db   # no auto-lock
```

Then store each secret with the launcher. It reads the secret without echo and hands it to `security` on stdin, so it never shows up in argv or your shell history:

```sh
zandy-claude --zandy-secret gitlab-token          # or: zandy secret set gitlab-token
```

The keychain never locks on its own; after a reboot, macOS asks for its password the first time zandy reads it. At launch zandy reads the secrets the gateway and adapters declare and keeps them in memory. The proxy and the adapters read them as an env file or a config file that is a named pipe in `~/.zandy/run/<pid>`, which the sandbox can't open; the text passes through the pipe each time they start and never lands on disk. Never through their environment.

Don't export secrets in the shell that starts zandy. A process in the sandbox can read the environment of every process running as your user with `sysctl kern.procargs2`, and Seatbelt can't block it.

If Bedrock answers `refresh cached SSO token failed … InvalidGrantException`, the SSO session has expired: run `aws sso login --profile <profile>` again.

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

The agent then calls `zandy-client call mac.say '{"voice":"Bad News","text":"the tests failed"}'`. `say` is not a Nix package, so a one-line wrapper calls `/usr/bin/say`; it runs in the broker, where `/usr/bin` is reachable. A real adapter declares its secrets and how its tool reads them; see [nix/adapters/gitlab.nix](nix/adapters/gitlab.nix), which writes the token into a glab config file.

| Field | Meaning |
|---|---|
| `name` | Prefix of the method names: `<name>.<capability>` |
| `package` | Derivation the broker runs; must not be in `packages` or the preset's packages |
| `binary` | Program in `package/bin` |
| `env` | Env vars passed from the shell that started zandy, besides `PATH` and `HOME`; not for secrets |
| `secrets` | Where each secret lives, e.g. `secrets.GITLAB_TOKEN.keychain = { service = "gitlab-token"; }`; `store = "login"` reads the login keychain, `field` a path into a JSON value |
| `files` | Files the adapter reads, as `0600` named pipes in its private dir, filled on every call; `{secret.NAME}` becomes the secret, at most 4096 bytes in all |
| `setEnv` | Env vars set for the command; `{dir}` becomes the private dir |
| `capabilities` | The methods: `name`, `description`, `params`, `argv` |

How the broker runs a method:

- **argv.** Each element is a literal or a whole `{param}`; `"--repo={param}"` is not substituted. A `list` param expands to several arguments.
- **Params.** All are required. `string` and `choice` values may not start with `-`, so they can't become options. A `choice` with an empty `choices` list drops the method. `list` values pass through unchecked.
- **Process.** The command runs outside the sandbox, in the directory zandy started in. Exit 0 returns stdout to the agent; anything else returns stderr.

Whatever the command can do, the agent can do, including printing its own credential: `gitlab.cli` with `["config", "get", "token"]` returns the GitLab token. Prefer narrow methods with `string` and `choice` params over a `list` that passes arguments through: `git` with free arguments runs any command, e.g. via `-c core.sshCommand=…`. Avoid tools that read the project directory, like `git` or `make`: the agent can write there, and the command runs what the project configures, outside the sandbox.

## Development

```sh
nix develop -c zig build test   # while working on zandy
nix flake check                  # the same tests, built and run by Nix
```

`nix run` and `nix profile` only build zandy; the tests run in `nix flake check`, not on every machine that installs it.
