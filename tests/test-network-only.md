# Network-Only Sandbox Tests

## Network

| Scenario | Expected |
|---|---|
| Open a TCP connection to a public host on port 80 | Connection succeeds |
| Open a TCP connection to a public host on port 443 | Connection succeeds |
| Resolve a public DNS name | Returns an IP address |

## Write restrictions (CWD is read-only)

| Scenario | Expected |
|---|---|
| Create a file in CWD | Operation not permitted |
| Write to a file in CWD | Operation not permitted |
| Create a directory in CWD | Operation not permitted |

## Write restrictions (general filesystem)

| Scenario | Expected |
|---|---|
| Create a file in `/tmp` | Operation not permitted |
| Create a file in `$HOME` | Operation not permitted |
| Write to `/dev/null` | Success (explicitly allowed) |

## Read restrictions (credentials and personal data)

| Scenario | Expected |
|---|---|
| Read `~/.ssh/id_rsa` | Operation not permitted |
| Read `~/.aws/credentials` | Operation not permitted |
| Read `~/.netrc` | Operation not permitted |
| Read `~/.git-credentials` | Operation not permitted |
| Read `~/.kube/config` | Operation not permitted |
| Read `~/.npmrc` | Operation not permitted |
| Read `~/.zsh_history` | Operation not permitted |
| List `~/Desktop` | Operation not permitted |
| List `~/Documents` | Operation not permitted |
| List `~/Downloads` | Operation not permitted |
| List `~/Library/Keychains` | Operation not permitted |
| List `~/Library/Safari` | Operation not permitted |
| List `~/Library/Mail` | Operation not permitted |
| List `~/Library/Messages` | Operation not permitted |

## Read allowed

| Scenario | Expected |
|---|---|
| List CWD | Directory listing |
| List `/opt/homebrew` | Directory listing |
| List `/tmp/zandy` | Directory listing |
| List `/usr/share/icu` | Directory listing |
| List `/` | Directory listing |
| List `~/.config/opencode` | Directory listing |
| List `~/.local/share/opencode` | Directory listing |
| List `~/.cache/opencode` | Directory listing |

## Process execution

| Scenario | Expected |
|---|---|
| Run a shell built-in | Produces expected output |
| Spawn a child process | Process executes successfully |
