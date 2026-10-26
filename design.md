# Zandy Design

A macOS sandbox launcher with builtin profiles for well-known apps, inspired by OpenBSD's pledge().

## API

```
zandy --env <drv> [args...]   # run the env's preset in its sandbox, with the broker
zandy config --env <drv>      # print the manifest and the methods the agent sees
zandy --help
```

## Presets

A preset is the minimum correct set of sandbox permissions an app needs to function, plus what zandy passes to it: `binary`, `env` allowlist and startup `args`. Presets are Nix files under `nix/presets/`; `mkSandboxEnv` writes the chosen one into the env's `zandy.json`.

Presets are always required — there is no raw mode. Without a preset, the sandboxed process would crash or hang because the user can't know which mach lookups, IPC, or system operations an app requires.

## Nix

Nix is required and is the only source of truth. `zandy.lib.mkSandboxEnv` builds one derivation per sandbox:

- `sandbox/bin`: `buildEnv` of the preset's packages, `zandy-client` and the project's `packages`. The only `PATH` inside the sandbox; the preset's binary is `sandbox/bin/<binary>`.
- `store-paths`: the closure of `sandbox/bin` (`closureInfo`), one store path per line.
- `zandy.json`: the manifest: preset (binary, env names, args, SBPL rules), adapters (store-path binary, env names, capabilities with their choice values), policy, filesystem.
- `bin/zandy-<name>`: the launcher, `exec zandy --env $out "$@"`, so `nix run` works.

`zandy --env` resolves the path and parses it as a `StorePath`; `SandboxEnv.parse` turns `store-paths` and `zandy.json` into precise types. Every store path in the closure, plus the env itself, gets `(allow process-exec (subpath …))` and `(allow file-read* (subpath …))`; there is no blanket `process-exec`.

## Broker

The sandboxed agent gets no credentials. When it needs an external tool (e.g. `glab`), it asks the broker over a Unix socket, and the broker runs the command outside the sandbox.

### Request flow

```
zandy-client call aws.cli '{"profile":"acme-dev","args":["s3","ls"]}'
  → {"jsonrpc":"2.0","id":1,"method":"aws.cli","params":{"ticket":"…","args":{"profile":"acme-dev","args":["s3","ls"]}}}
broker: ticket → find (policy) → parseParams → buildArgv → run
  ← {"jsonrpc":"2.0","id":1,"result":"<stdout>"}   or   {"error":{"code":-32002,"message":"<stderr>"}}
```

`rpc.discover` returns every callable method with its description and a JSON schema of its params.

### Decisions

- **Adapters group capabilities.** An adapter owns what its capabilities share: `binary`, `env`, and the name prefix. Each capability has `params` and an `argv` template. `parseAdapters` turns adapters into a flat `[]const Capability` at broker start.
- **Parse, don't validate.** Config and requests are parsed into types the rest of the code relies on: `parseTemplate` turns `argv` into `Segment`s (`literal` or `param` index), `parseParams` turns `args` into `Args`. `buildArgv` only accepts those.
- **No shell, whole entries.** Placeholders must be a whole argv entry (`"{project}"`). A `string` param becomes one entry and may not start with `-`, so it can't become a flag. A `list` param expands into one entry per item and allows flags. A `choice` param only accepts the values configured under `adapters.<adapter>.<param>`; without values the capability isn't offered.
- **The outer process sets the scope.** The broker doesn't judge commands. `gitlab.cli` and `aws.cli` pass everything through; the token's scopes and the profile's IAM permissions decide. The broker keeps credentials outside and appends the chosen `--profile` last, so it wins.
- **Honest effects.** Passthrough capabilities are `admin` and need `"policy": {"admin": "allow"}`.
- **Backend credentials come from the broker.** `backend` is `bedrock` (`profile`, `region`), required by the claude preset. `mkSandboxEnv` adds the `backend.credentials` adapter (`aws configure export-credentials`), and the claude preset's args get `--settings` with `awsCredentialExport` pointing at it. The agent can call it too, so the profile's account should only host Bedrock.
- **The agent is told.** Each preset passes its own startup args; claude gets `--append-system-prompt` explaining `zandy-client`.
- **No secrets in Nix.** `/nix/store` is world-readable. The manifest holds env names; values come from zandy's environment at launch.
- **Adapters stay outside.** An adapter's package must not be in the sandbox closure: `mkSandboxEnv` asserts it for direct packages, `SandboxEnv.parse` checks every adapter binary against the whole closure.
- **Only `allow`.** `discover` and calls only see capabilities whose effect the policy allows (`read` by default, configurable via `policy` in the config). `ask` behaves like `deny` until there is a prompt.
- **Allowlisted environment.** zandy never edits its own environment. The sandboxed process gets a fresh `Environ.Map` with only the names its preset lists in `env`, plus `BROKER_SOCK`/`BROKER_TICKET`. There is no shared base list; each preset declares everything its process needs. Everything else, including adapter secrets, stays out. The adapter command gets only `PATH`, `HOME` and its adapter's `env`.
- **Network is narrowed, not closed.** The profiles only allow TCP to `*:443`, the DNS socket, and `(param "BROKER_SOCK")`. TCP can't be restricted by hostname in SBPL, so keeping secrets out of the sandbox (env, files, keychain) is the actual protection.
- **Config comes from the env.** Adapters, presets and policy are Nix; zandy has no config files and parses everything at runtime from `zandy.json`.
- **Thin client.** `zandy-client` passes JSON through and prints the result. The agent reads the `discover` JSON directly.
