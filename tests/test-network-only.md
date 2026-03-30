# Network-Only Sandbox Tests

Run zandy with `--network-only`, then run each command inside the opencode session and verify the expected result.

## Network (should work)

| Command | Expected |
|---|---|
| `curl -s -o /dev/null -w "%{http_code}" https://api.anthropic.com` | `307` or any HTTP response (not a connection error) |
| `curl -s -o /dev/null -w "%{http_code}" https://openai.com` | `200` or any HTTP response |

## Write restrictions (CWD is read-only)

| Command | Expected |
|---|---|
| `touch /Users/tbsklg/tmp/evil` | Operation not permitted |
| `echo test > /Users/tbsklg/tmp/test.txt` | Operation not permitted |
| `mkdir /Users/tbsklg/tmp/newdir` | Operation not permitted |

## Write allowed (target dir)

| Command | Expected |
|---|---|
| `echo test > /tmp/zandy/test.txt && rm /tmp/zandy/test.txt` | no error |
| `mkdir /tmp/zandy/newdir && rmdir /tmp/zandy/newdir` | no error |

## Read restrictions (credentials and personal data)

| Command | Expected |
|---|---|
| `cat ~/.ssh/id_rsa` | Operation not permitted |
| `cat ~/.aws/credentials` | Operation not permitted |
| `cat ~/.netrc` | Operation not permitted |
| `cat ~/.git-credentials` | Operation not permitted |
| `cat ~/.kube/config` | Operation not permitted |
| `cat ~/.npmrc` | Operation not permitted |
| `cat ~/.zsh_history` | Operation not permitted |
| `ls ~/Desktop` | Operation not permitted |
| `ls ~/Documents` | Operation not permitted |
| `ls ~/Downloads` | Operation not permitted |
| `ls ~/Library/Keychains` | Operation not permitted |
| `ls ~/Library/Safari` | Operation not permitted |
| `ls ~/Library/Mail` | Operation not permitted |
| `ls ~/Library/Messages` | Operation not permitted |

## Read allowed

| Command | Expected |
|---|---|
| `ls /Users/tbsklg/tmp` | directory listing |
| `cat /Users/tbsklg/dotfiles/config/opencode/opencode.json` | file contents |
| `ls /opt/homebrew` | directory listing |
| `ls /tmp/zandy` | directory listing |
