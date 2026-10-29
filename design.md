# Zandy Design

A macOS sandbox launcher with builtin profiles for well-known apps, built around Nix.

## Platform

macOS on Apple Silicon only, by design. zandy is built on Seatbelt and the macOS keychain; there is no support for Intel Macs, Linux or Windows, and none is planned.

## Principles

- **A pure function of its declaration.** One flake describes everything an agent gets: tools, filesystem, network, credentials and the model backend. The same flake always yields the same sandbox; nothing outside it, no global config or state in `$HOME`, changes the result.
- **Immutable.** The built sandbox is a read-only value in `/nix/store`. Changing it means changing the declaration and building a new one, not mutating the old one.
- **No credentials inside the sandbox.** Effects that need them happen outside, in the broker or the gateway, through explicit requests.
- **Parse, don't validate.** Every input is parsed into a precise type, once, at the boundary: the flake by the Nix options, the manifest and requests by zandy.

## API

```
zandy --env <drv> [args...]   # run the env's preset in its sandbox, with the broker
zandy config --env <drv>      # print the manifest and the methods the agent sees
zandy --env <drv> --zandy-config  # the same, as zandy-<name> --zandy-config from the launcher
zandy secret set <service>    # store a secret in ~/.zandy/zandy.keychain-db
zandy --env <drv> --zandy-secret <service>  # the same, as zandy-<name> --zandy-secret from the launcher
zandy --help
```

## Presets

A preset is the minimum correct set of sandbox permissions an app needs to function, plus what zandy passes to it: `binary`, `env` allowlist and startup `args`. Presets are Nix files under `nix/presets/`; `mkSandboxEnv` writes the chosen one into the env's `zandy.json`.

Presets are always required — there is no raw mode. Without a preset, the sandboxed process would crash or hang because the user can't know which mach lookups, IPC, or system operations an app requires.

## Nix, Zig and Seatbelt

Nix decides what goes into a sandbox, at build time. Zig turns that into a sandbox profile, starts the gateway and runs the broker. Seatbelt, the macOS kernel sandbox, enforces the profile.

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

**Nix describes the sandbox.** It decides which tools live inside, which stay outside behind the broker, and what the agent may ask for. The result is reproducible, read-only and holds no secrets.

**Zig connects the two.** It translates what Nix described into a Seatbelt profile, brings in secrets only outside the sandbox, and mediates every request that crosses the boundary.

**Seatbelt enforces it.** The kernel confines the agent to that profile: what it may read, write, execute and connect to. Once applied, the agent can't loosen it.

## Broker

The sandboxed agent gets no credentials. When it needs an external tool (e.g. `glab`), it asks the broker over a Unix socket, and the broker runs the command outside the sandbox.

### Request flow

```
zandy-client call aws.cli '{"profile":"acme-dev","args":["s3","ls"]}'
  → {"jsonrpc":"2.0","id":1,"method":"aws.cli","params":{"ticket":"…","args":{"profile":"acme-dev","args":["s3","ls"]}}}
broker: ticket → find → parseParams → buildArgv → run
  ← {"jsonrpc":"2.0","id":1,"result":"<stdout>"}   or   {"error":{"code":-32002,"message":"<stderr>"}}
```

`rpc.discover` returns every callable method with its description and a JSON schema of its params.

### Decisions

- **Adapters group capabilities.** An adapter holds the shared `binary`, `env` and name prefix; each capability adds `params` and an `argv` template.
- **Parse, don't validate.** Config and requests are parsed into precise types; `buildArgv` only accepts those.
- **No shell.** Each placeholder is a whole argv entry. `string` params can't start with `-`, `list` params can, `choice` params only take configured values.
- **The outer process sets the scope.** The broker doesn't judge commands; token scopes and IAM permissions do.
- **No secrets in the sandbox.** The manifest holds where a secret lives, never its value; zandy reads it from the keychain at launch. The sandbox gets only its preset's `env`, `BROKER_SOCK`/`BROKER_TICKET` and the gateway's URL; adapter binaries stay outside its closure.
- **Exec allowlist.** Only the env's closure may be executed, plus `/bin/sh` and `/bin/bash` for claude.
- **Protected files.** The working directory is writable, except `flake.nix`, `flake.lock`, `.envrc`, `.git/config` and `.git/hooks`.
- **Network is narrowed.** Only TCP to `*:443`, DNS, the broker socket and the gateway's port on localhost.

## Gateway

The model backend is not an adapter. Adapters return a command's output; a model client needs an HTTP endpoint it can stream from. The gateway is that endpoint: a local proxy zandy starts outside the sandbox, holding the credentials and forwarding to one fixed upstream.

```
agent ── HTTP ──▶ gateway (127.0.0.1:<port>, outside) ── HTTPS + auth ──▶ upstream
```

- **zandy speaks no HTTP.** The proxy is a ready-made program: Caddy for Anthropic and OpenAI, `aws-sigv4-proxy` for Bedrock. zandy picks a free port, passes it as `ZANDY_GATEWAY_PORT` and `{port}` in `argv`, starts the process, waits until it listens and stops it at the end.
- **Declared in Nix.** A gateway is `{ name; argv; env; secrets; files; }` in the manifest. Caddy's config is a Nix attrset written as JSON: admin API off, errors-only logs, the auth header set from `{env.KEY}` at request time, the sandbox's own credential headers deleted.
- **Secrets are sources, not values.** `secrets` maps a name to where its value lives, e.g. `keychain = { service; field; store; }`; gateways and adapters declare them the same way. The manifest names the item, never its contents.
- **One upstream, one port.** The sandbox may connect to the gateway's port and no other localhost port; the proxy, not the agent, decides the host.
- **The credential sets the scope.** As for adapters, zandy doesn't judge requests; the key's or IAM role's permissions do.
- **One gateway at a time.** A preset's `gatewayEnv` maps each gateway name to the env vars its app needs, with `{url}` filled in at launch.

## Secrets

```
zandy.keychain-db ──security──▶ zandy (memory) ──named pipe──▶ ~/.zandy/run/<pid>/<gateway|adapter-name>/ ──▶ proxy, adapter
```

- **zandy's own keychain.** `~/.zandy/zandy.keychain-db`, created once with `security create-keychain`, without auto-lock and outside the keychain search list. `store = "login"` reads the login keychain instead, for items another app writes, like claude's login.
- **Never through an environment or argv.** On macOS any process can read the environment and arguments of every process of its user with `sysctl kern.procargs2`; Seatbelt has no rule that blocks it, neither `sysctl-read` filters nor `process-info*`. So secrets reach their consumer only through named pipes: each declared file is a `0600` FIFO, and zandy writes the filled-in text into it whenever the consumer starts, once for the gateway and on every call for an adapter. Nothing lands on disk, so nothing is left behind if zandy dies. Caddy loads `secrets.env` with `--envfile`, which sets them inside the process, after the strings `procargs2` reads; glab reads `config.yml` from `GLAB_CONFIG_DIR`.
- **Private dirs the sandbox can't reach.** Each consumer gets `~/.zandy/run/<pid>/<name>/`, `0700`, its pipes `0600`; `{dir}` in `argv`, `env` and `setEnv` names it. zandy denies reading and writing under `~/.zandy` after every other rule, so no preset or `filesystem` setting can open it, and deletes the session dir at exit.
- **One read per run.** A pipe carries the text for one read: a consumer that opens its file twice in one run, or writes to it, would hang. Caddy and glab read once. A filled-in file is at most 4096 bytes, so zandy's write always fits the pipe's buffer, and the broker serves one call at a time, so two calls never share a pipe.
- **Secrets are single-line.** A value with a newline is rejected, so it can't add lines to an env or config file.
- **No keychain in the sandbox.** zandy denies `mach-lookup` to `com.apple.SecurityServer` and `com.apple.securityd.xpc`, and reading or writing `~/Library/Keychains`, after every other rule, whatever the preset allows.

## Known issues

- git aborts with `unable to access '~/.config/git/config': Operation not permitted`: the presets don't allow reading the global git config.
- Secrets exported in the shell that starts zandy can be read from the sandbox through `kern.procargs2` (see [Secrets](#secrets)); store them with `zandy secret set` instead.
- A tool behind a `list` param can print its own credential, e.g. `gitlab.cli` with `["config", "get", "token"]`.
- The opencode preset asks for the Security services, which zandy now denies; it hasn't been tested without them.
- A long `$HOME` fails with `NameTooLong`: `~/.zandy/run/<pid>/broker.sock` must fit the 104 bytes of a Unix socket path.
- Keep `AWS_PROFILE` and `awsCredentialExport` out of `~/.claude/settings.json`, otherwise claude tries to resolve AWS credentials inside the sandbox instead of using the gateway.
- Bedrock answers `refresh cached SSO token failed … InvalidGrantException` when the SSO session has expired: `aws sso login --profile <profile>`.
- `aws-sigv4-proxy` prints a few info lines on stderr at startup, before the agent's UI appears.
- `glab auth login` stores its token in `~/.config/glab-cli/config.yml`. The presets don't allow reading it; keep it that way, or the agent can bypass the broker.
- `opencode` fails with `operation not permitted mkdir '/var/folders/…'`: start it once without zandy, then with zandy.
