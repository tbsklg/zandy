# Backlog

Baby-step user stories for the generic preset API. Starting point: bare
`zandy` launches opencode with the builtin profile. Implement in order;
each story leaves `zig build test` green and the binary working. Acceptance
criteria show exactly what the user types and sees.

## Story 1: Named presets — `zandy opencode`

As a user, I want to say `zandy opencode` so that zandy can support more
apps over time.

Acceptance criteria:
- `zandy opencode` → opencode starts, exactly like bare `zandy` does today.
- `zandy` → prints the usage text (presets: `opencode`; promises: `inet`,
  `rpath`, `wpath`, `fwrite`; examples) to stderr, exit 1.
- `zandy bogus` → prints:
  ```
  zandy: unknown preset 'bogus'
  available presets: opencode
  ```
  exit 1.

## Story 2: `--help`

As a user, I want `zandy --help` so that I can discover usage without
triggering an error.

Acceptance criteria:
- `zandy --help` → prints the same usage text as bare `zandy`, but to
  stdout, exit 0.
- `zandy -h` → identical behavior.
- `zandy` (no args) → still prints usage to stderr, exit 1.

## Story 3: Binaries are found without external tools

As a user, I want zandy to locate binaries on its own so that it works the
same for any program, not just opencode.

Acceptance criteria:
- `zandy opencode` → opencode starts, exactly as before.
- `zandy opencode` with `opencode` absent from PATH → prints
  `zandy: 'opencode' not found in PATH`, exit 1.

## Story 4: Explicit binary path and argument forwarding

As a user, I want `zandy opencode -- /custom/path --verbose` so that I can
sandbox a specific binary and pass arguments through to it.

Acceptance criteria:
- `zandy opencode -- /bin/echo hello` → prints `hello`.
- `zandy opencode -- /explicit/path/to/opencode` → that exact binary
  starts; PATH is not consulted.
- `zandy opencode` (no `--`) → behaves exactly like Story 3.

## Story 5: A `base` preset for arbitrary tools

As a user, I want `zandy base -- /usr/bin/curl …` so that I can sandbox
tools that have no dedicated preset.

Acceptance criteria:
- `zandy base -- /bin/echo hi` → prints `hi`.
- `zandy base -- /usr/bin/curl -sI https://example.com` → the request
  fails; curl exits non-zero.
- `zandy` → usage now lists presets `opencode` and `base`.

## Story 6: Promise names are recognized

As a user, I want a fixed vocabulary of promise names so that I can request
extra capabilities without knowing sandbox internals.

Acceptance criteria (via `zig build test`; not yet in the CLI):
- `inet`, `rpath`, `wpath`, `fwrite` are accepted.
- `"inet wpath"` is accepted as two promises.
- An empty request is accepted.
- `"bogus"` is rejected, naming the invalid promise.

## Story 7: Each promise grants a minimal, documented capability

As a user, I want to know exactly what each promise allows so that the
sandbox stays as tight as possible.

Acceptance criteria (via `zig build test`, inspecting the generated
sandbox profile):
- `inet` allows outbound network — and nothing else new.
- `rpath` allows reading the working directory.
- `wpath` allows writing in the working directory.
- `fwrite` allows creating files in the working directory.

## Story 8: Extending a preset with promises

As a user, I want `zandy -p "wpath" opencode` so that I can grant extra
capabilities without editing any files.

Acceptance criteria:
- `zandy -p "wpath" opencode` → opencode starts with write access to the
  working directory.
- `zandy -p "inet wpath" opencode` → both capabilities granted.
- `zandy -p "bogus" opencode` → prints:
  ```
  zandy: unknown promise 'bogus'
  available promises: inet, rpath, wpath, fwrite
  ```
  exit 1; nothing is launched.
- `zandy opencode` (no `-p`) → behaves exactly like Story 4.
- `zandy -p "inet" base -- /usr/bin/curl -sI https://example.com` → the
  request succeeds (compare Story 5, where it fails).

## Story 9: The network-only variant becomes a preset

As a user, I want `zandy opencode-network-only` so that profile variants
are just presets with names.

Acceptance criteria:
- `zandy opencode-network-only` → opencode starts; it can read files in
  the working directory but modifying them fails.
- `zandy --profile network_only` → prints:
  ```
  zandy: unknown flag '--profile'
  profiles were replaced by presets; try 'zandy opencode-network-only'
  ```
  exit 1.
- `zandy` → usage now lists `opencode-network-only` too.

## Story 10: Documentation matches reality

As a user, I want the README to teach me presets and promises so that I
don't have to read the source.

Acceptance criteria:
- Every command in the README can be copy-pasted and produces the
  documented output.
- The README lists every preset and every promise with its meaning.
- `--profile` is not mentioned anywhere in the docs.
