# Default Sandbox Tests

Run zandy (without flags), then verify each scenario inside the opencode session.

Note: The default profile uses a **deny-default** policy with CWD read+write access. Network is allowed. Sensitive paths outside CWD are denied because they are never explicitly allowed.

## Read restrictions (credentials and personal data)

| Scenario | Expected |
|---|---|
| Read `~/.ssh/id_rsa` | Operation not permitted |
| Read `~/.aws/credentials` | Operation not permitted |
| Read `~/.docker/config.json` | Operation not permitted |
| Read `~/.netrc` | Operation not permitted |
| Read `~/.git-credentials` | Operation not permitted |
| Read `~/.kube/config` | Operation not permitted |
| Read `~/.npmrc` | Operation not permitted |
| Read `~/.env` | Operation not permitted |
| Read `~/.envrc` | Operation not permitted |
| Read `~/.zsh_history` | Operation not permitted |
| List `~/Desktop` | Operation not permitted |
| List `~/Documents` | Operation not permitted |
| List `~/Downloads` | Operation not permitted |
| List `~/Library/Keychains` | Operation not permitted |
| List `~/Library/Safari` | Operation not permitted |
| List `~/Library/Mail` | Operation not permitted |
| List `~/Library/Messages` | Operation not permitted |

## Rename/move bypass

| Scenario | Expected |
|---|---|
| Move `~/.ssh` to `/tmp/` | Operation not permitted |
| Move `~/.aws/credentials` to `/tmp/` | Operation not permitted |
| Move `~/.netrc` to `/tmp/` | Operation not permitted |

## Process restrictions

| Scenario | Expected |
|---|---|
| List all system processes | Operation not permitted or empty |
| Send a signal to PID 1 | Operation not permitted |

## Write restrictions (outside CWD)

| Scenario | Expected |
|---|---|
| Create a file in `$HOME` (outside CWD) | Operation not permitted |
| Write to `/dev/null` | Success (explicitly allowed) |

## Normal operation

| Scenario | Expected |
|---|---|
| Run a shell built-in | Produces expected output |
| Read a file in CWD | File contents displayed |
| Create and delete a file in CWD | No error |
| Create a file in `/tmp` | Operation not permitted |
| Spawn a child process | Process executes successfully |
| Open a TCP connection to a public host | Connection succeeds |
| Resolve a public DNS name | Returns an IP address |
