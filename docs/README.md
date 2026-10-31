# zandy.nix docs

- [Install](#install)
- [Per project](#per-project)
- [Configuration](#configuration)
- [Model backends](#model-backends)
- [Secrets](#secrets)
- [Inside the sandbox](#inside-the-sandbox)
- [Write your own adapter](#write-your-own-adapter)
- [Debug log](logging.md)
- [Security limits](#security-limits)
- [Troubleshooting](#troubleshooting)
- [Development](#development)

## Install

zandy runs on macOS on Apple Silicon. Everything it needs comes from Nix: Zig, claude, glab, aws and the gateway proxies.

Install Nix and enable flakes:

```sh
sh <(curl --proto '=https' --tlsv1.2 -L https://nixos.org/nix/install)
mkdir -p ~/.config/nix && echo "experimental-features = nix-command flakes" >> ~/.config/nix/nix.conf
```

Create your env from the template:

```sh
mkdir -p ~/.config/zandy && cd ~/.config/zandy
nix flake init -t github:tbsklg/zandy.nix
```

Edit `flake.nix`: replace the `acme-*` profiles and remove any adapters you don't need. Then install it:

```sh
git init && git add -A            # flakes only see files git tracks
nix profile add ~/.config/zandy   # older Nix: nix profile install
```

Before the first run you need:

- a [model backend](#model-backends), e.g. a logged-in AWS profile with Bedrock access
- a login for your adapters' tools, e.g. `glab auth login` for the GitLab adapter

Start the agent from a project directory:

```sh
cd ~/code/widgets
zandy-claude
```

To see the env's config, the broker methods and the Seatbelt profile without starting the agent, run `zandy-claude --zandy-config`.

After changing `flake.nix`:

```sh
git add -A && nix flake update zandy && nix profile upgrade --all
```

## Per project

If a project needs its own toolchain, give it its own env and add the tools to `packages`.

Keep that flake in its own directory outside the project. Then it doesn't have to be committed, and the agent can't edit it. Start it from the project root:

```sh
cd ~/code/widgets
nix run ~/.config/zandy/widgets
```

## Configuration

```nix
zandy.lib.mkSandboxEnv {
  inherit pkgs;
  name = "claude";
  preset = zandy.presets.claude;
  packages = [ pkgs.ripgrep ];
  gateway = zandy.gateways.bedrock { profile = "acme-bedrock"; region = "eu-west-1"; };
  adapters = [
    (zandy.adapters.gitlab { })
    (zandy.adapters.aws { profiles = [ "acme-dev" ]; })
  ];
  filesystem.allowRead = [ "~/notes" ];
}
```

| Option | What it sets |
|---|---|
| `name` | The env's name. The launcher is called `zandy-<name>` |
| `preset` | The app to run and the sandbox rules it needs: `zandy.presets.claude` or `zandy.presets.opencode` |
| `packages` | Extra programs the agent may run |
| `gateway` | The [model backend](#model-backends) |
| `adapters` | Tools the broker runs outside the sandbox for the agent |
| `filesystem` | Extra paths the agent may read or write, or may not |

A mistyped or unknown option fails at build time. For all options with their types and defaults, see [options.md](options.md). It is generated with `nix build .#options-doc`.

## Model backends

The agent reaches its model through a gateway. That's a local proxy that zandy starts outside the sandbox. It adds the credentials and forwards requests to one fixed upstream. The sandbox can reach the gateway's port, but never sees the key.

You pick one gateway per env. Without one, the agent reaches no model through zandy.

### Bedrock

```nix
gateway = zandy.gateways.bedrock { profile = "acme-bedrock"; region = "eu-west-1"; };
```

Needs an AWS profile with Bedrock access in `~/.aws/config`, logged in with e.g. `aws sso login --profile acme-bedrock`.

### Anthropic API key

```nix
gateway = zandy.gateways.anthropic { };
```

Needs the API key, stored with `zandy-claude --zandy-secret anthropic-api-key`.

### Claude subscription

```nix
gateway = zandy.gateways.anthropicOauth { };
```

Uses your Claude login. Run `claude` once outside zandy and log in. zandy reads the token from your login keychain at start.

### OpenAI

```nix
gateway = zandy.gateways.openai { };
```

Needs the API key, stored with `zandy-claude --zandy-secret openai-api-key`. Set `host` for an OpenAI-compatible API other than `api.openai.com`. No preset uses this gateway yet.

## Secrets

Adapters use the tool's own login: `aws sso login` for the AWS adapter, `glab auth login` for the GitLab adapter. The tool keeps its credentials where it always does, and the sandbox can't read them. You chose the tool, so how it stores its token is up to you and the tool.

zandy only keeps the secrets of its own gateways, in its own keychain, `~/.zandy/zandy.keychain-db`, outside the sandbox.

Create the keychain once. `security` asks you for a password for it:

```sh
security create-keychain ~/.zandy/zandy.keychain-db
security set-keychain-settings ~/.zandy/zandy.keychain-db   # no auto-lock
```

Store a secret:

```sh
zandy-claude --zandy-secret anthropic-api-key
```

zandy asks for the secret without echoing it, so it doesn't end up in your shell history. The keychain doesn't lock on its own. After a reboot, macOS asks for its password the first time zandy reads it.

At launch, zandy reads the secrets that the gateway needs. They reach the proxy through named pipes in a private directory that the sandbox can't open. They never touch the disk and are never passed through an environment variable.

Don't export secrets in the shell that starts zandy. See [Security limits](#security-limits) for why.

## Inside the sandbox

The agent:

- can write to the project directory, except `flake.nix`, `flake.lock`, `.envrc`, `.git/config` and `.git/hooks`
- can run only programs from the env, so no Homebrew, `/usr/bin` or downloaded binaries
- can connect only to port 443, DNS and the gateway
- can't read the keychain or `~/.zandy`

It reaches your tools through the broker:

```sh
zandy-client discover
zandy-client call gitlab.cli '{"args":["issue","list","--repo","group/name"]}'
```

The broker runs the command outside the sandbox. zandy doesn't judge what the command does. The token's scopes and the profile's IAM permissions decide that.

## Write your own adapter

An adapter is a function that takes `pkgs` and returns an attrset. Define it in your flake and add it to `adapters`.

This one lets the agent use macOS text-to-speech, which the sandbox can't reach:

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

The agent then calls:

```sh
zandy-client call mac.say '{"voice":"Bad News","text":"the tests failed"}'
```

If the tool has its own login, let it use that, like [nix/adapters/gitlab.nix](../nix/adapters/gitlab.nix). Only for a tool without one, hand it a secret from zandy's keychain with `secrets` and `files`.

### Fields

| Field | Meaning |
|---|---|
| `name` | Prefix of the method names: `<name>.<capability>` |
| `package` | The derivation the broker runs. Must not also be in `packages` |
| `binary` | The program in `package/bin` |
| `capabilities` | The methods: `name`, `description`, `params`, `argv` |
| `env` | Env vars passed on from the shell that started zandy. Not for secrets |
| `secrets` | Where each secret lives, e.g. `secrets.ACME_TOKEN.keychain = { service = "acme-token"; }`. Add `store = "login"` to read from the login keychain, or `field` to pick a path inside a JSON value |
| `files` | Files the tool reads. `{secret.NAME}` is replaced with the secret. At most 4096 bytes in total |
| `setEnv` | Env vars set for the command. `{dir}` is replaced with the adapter's private directory |

### How a call runs

- **argv:** each element is either a literal or a whole `{param}`. `"--repo={param}"` is not substituted. A `list` param expands to several arguments.
- **params:** all params are required. `string` and `choice` values can't start with `-`, so they can't become options. `list` values are passed through unchecked.
- **result:** the command runs outside the sandbox, in the directory zandy started in. On exit 0 the agent gets stdout, otherwise stderr.

Whatever the command can do, the agent can do too. Prefer narrow methods with `string` and `choice` params over a `list` that passes anything through. Avoid tools that read the project directory, like `git` or `make`. The agent can write there, and the tool would run whatever the project configures, outside the sandbox.

## Security limits

- **Environment variables are readable.** On macOS, any process can read the environment and arguments of every other process run by the same user. Seatbelt can't block that. So don't export secrets in the shell that starts zandy. Store them with `--zandy-secret` instead.
- **Tools can print their own credentials.** `gitlab.cli` with `["config", "get", "token"]` returns the GitLab token. Narrow methods avoid this.
- **Tools keep their credentials in your home.** glab keeps its token in `~/.config/glab-cli/config.yml`, aws in `~/.aws`. The sandbox can't read them. Keep it that way: an `allowRead` for `~` or `~/.config` hands them to the agent, and then it can bypass the broker.

## Troubleshooting

| Symptom | Fix |
|---|---|
| Bedrock: `refresh cached SSO token failed … InvalidGrantException` | The SSO session expired. Run `aws sso login --profile <profile>` |
| `Operation not permitted` | Look up the blocked operation in the [debug log](logging.md) |
| git: `unable to access '~/.config/git/config': Operation not permitted` | Your config is a symlink, e.g. from home-manager. The sandbox checks the target, so add it to `filesystem.allowRead` |
| claude tries to resolve AWS credentials inside the sandbox | Remove `AWS_PROFILE` and `awsCredentialExport` from `~/.claude/settings.json` |
| `NameTooLong` at start | Your `$HOME` path is too long. `~/.zandy/run/<pid>/broker.sock` must fit in 104 bytes |
| opencode: `operation not permitted mkdir '/var/folders/…'` | Start opencode once without zandy, then with zandy |
| A few info lines on stderr before the agent starts | That's `aws-sigv4-proxy` starting up. They're harmless |

## Development

```sh
nix develop -c zig build test   # while working on zandy
nix flake check                 # the same tests, built and run by Nix
```

To try a local checkout of zandy in your env, override its `zandy` input:

```sh
cd ~/code/widgets
nix run --override-input zandy path:$HOME/code/zandy ~/.config/zandy
```

Use `path:`, not a plain path: a plain path is read as a git repo, which leaves out files git doesn't track yet.

Planned work is in [TODO.md](../TODO.md).
