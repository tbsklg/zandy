# Sandbox Tests

Run each command and verify the expected result.

## Read restrictions

| Command | Expected |
|---|---|
| `cat ~/.ssh/id_rsa` | Operation not permitted |
| `cat ~/.aws/credentials` | Operation not permitted |
| `cat ~/.docker/config.json` | Operation not permitted |
| `cat ~/.netrc` | Operation not permitted |
| `cat ~/.git-credentials` | Operation not permitted |
| `cat ~/.kube/config` | Operation not permitted |
| `cat ~/.npmrc` | Operation not permitted |
| `cat ~/.env` | Operation not permitted |
| `cat ~/.envrc` | Operation not permitted |
| `cat .envrc` | Operation not permitted |
| `cat .env` | Operation not permitted |
| `cat ~/.zsh_history` | Operation not permitted |
| `ls ~/Library/Keychains` | Operation not permitted |
| `ls ~/Library/Safari` | Operation not permitted |
| `ls ~/Desktop` | Operation not permitted |
| `ls ~/Documents` | Operation not permitted |
| `ls ~/Downloads` | Operation not permitted |
| `ls ~/Library/Mail` | Operation not permitted |
| `ls ~/Library/Messages` | Operation not permitted |

## Rename/move bypass

| Command | Expected |
|---|---|
| `mv .envrc /tmp/stolen && cat /tmp/stolen` | Operation not permitted |
| `mv ~/.ssh /tmp/stolen_ssh` | Operation not permitted |
| `mv ~/.aws/credentials /tmp/stolen_aws` | Operation not permitted |
| `mv ~/.netrc /tmp/stolen_netrc` | Operation not permitted |

## Process restrictions

| Command | Expected |
|---|---|
| `ps aux` | Operation not permitted or empty |
| `kill -0 1` | Operation not permitted |

## Normal operation

| Command | Expected |
|---|---|
| `echo hello` | hello |
| `cat opencode.sh` | file contents |
| `echo test > /tmp/sandbox_test && rm /tmp/sandbox_test` | no error |
| `echo test > sandbox_test && rm sandbox_test` | no error |
