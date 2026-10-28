# Zandy Design

A macOS sandbox launcher with builtin profiles for well-known apps, built around Nix.

## API

```
zandy --env <drv> [args...]   # run the env's preset in its sandbox, with the broker
zandy config --env <drv>      # print the manifest and the methods the agent sees
zandy --env <drv> --zandy-config  # the same, as zandy-<name> --zandy-config from the launcher
zandy --help
```

## Presets

A preset is the minimum correct set of sandbox permissions an app needs to function, plus what zandy passes to it: `binary`, `env` allowlist and startup `args`. Presets are Nix files under `nix/presets/`; `mkSandboxEnv` writes the chosen one into the env's `zandy.json`.

Presets are always required — there is no raw mode. Without a preset, the sandboxed process would crash or hang because the user can't know which mach lookups, IPC, or system operations an app requires.

## Nix, Zig and Seatbelt

Nix decides what goes into a sandbox, at build time. Zig turns that into a sandbox profile, starts the gateway and runs the broker. Seatbelt, the macOS kernel sandbox, enforces the profile.

![overview](docs/overview.png)

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
- **No secrets in the sandbox.** The manifest holds env names, values come from zandy's environment. The sandbox gets only its preset's `env`, `BROKER_SOCK`/`BROKER_TICKET` and the gateway's URL; adapter binaries stay outside its closure.
- **Exec allowlist.** Only the env's closure may be executed, plus `/bin/sh` and `/bin/bash` for claude.
- **Protected files.** The working directory is writable, except `flake.nix`, `flake.lock`, `.envrc`, `.git/config` and `.git/hooks`.
- **Network is narrowed.** Only TCP to `*:443`, DNS, the broker socket and the gateway's port on localhost.

## Gateway

The model backend is not an adapter. Adapters return a command's output; a model client needs an HTTP endpoint it can stream from. The gateway is that endpoint: a local proxy zandy starts outside the sandbox, holding the credentials and forwarding to one fixed upstream.

```
agent ── HTTP ──▶ gateway (127.0.0.1:<port>, outside) ── HTTPS + auth ──▶ upstream
```

- **zandy speaks no HTTP.** The proxy is a ready-made program: Caddy for Anthropic and OpenAI, `aws-sigv4-proxy` for Bedrock. zandy picks a free port, passes it as `ZANDY_GATEWAY_PORT` and `{port}` in `argv`, starts the process, waits until it listens and stops it at the end.
- **Declared in Nix.** A gateway is `{ name; argv; env; }` in the manifest. Caddy's config is a Nix attrset written as JSON: admin API off, errors-only logs, the auth header set from `{env.KEY}` at request time, the sandbox's own credential headers deleted.
- **One upstream, one port.** The sandbox may connect to the gateway's port and no other localhost port; the proxy, not the agent, decides the host.
- **The credential sets the scope.** As for adapters, zandy doesn't judge requests; the key's or IAM role's permissions do.
- **One gateway at a time.** A preset's `gatewayEnv` maps each gateway name to the env vars its app needs, with `{url}` filled in at launch.

## Known issues

- git aborts with `unable to access '~/.config/git/config': Operation not permitted`: the presets don't allow reading the global git config.
- Keep `AWS_PROFILE` and `awsCredentialExport` out of `~/.claude/settings.json`, otherwise claude tries to resolve AWS credentials inside the sandbox instead of using the gateway.
- Bedrock answers `refresh cached SSO token failed … InvalidGrantException` when the SSO session has expired: `aws sso login --profile <profile>`.
- `aws-sigv4-proxy` prints a few info lines on stderr at startup, before the agent's UI appears.
- `glab auth login` stores its token in `~/.config/glab-cli/config.yml`. The presets don't allow reading it; keep it that way, or the agent can bypass the broker.
- `opencode` fails with `operation not permitted mkdir '/var/folders/…'`: start it once without zandy, then with zandy.
