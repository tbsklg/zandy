# Debug log

zandy logs to the macOS unified log under the subsystem `tbsklg.zandy`, with one category per scope:

- `zandy`: the session, the secrets loaded by name, the profile and how the agent exited
- `broker`: each method the agent called, with its outcome and duration, and for a failed command its exit status
- `gateway`: when the gateway started and stopped

Each operation the sandbox blocks is logged by macOS itself and tagged `zandy-<pid>`, where `<pid>` is the session in the first `zandy` line. The log holds no params, output or secret values, except the first stderr line of a failed command at `debug` level, which macOS doesn't keep on disk. The agent can't read it. To see the full Seatbelt profile, run `zandy-<name> --zandy-config`.

Open a second terminal and run one of the following commands:

```sh
log stream --level debug --predicate 'subsystem == "tbsklg.zandy" OR (senderImagePath ENDSWITH "/Sandbox" AND eventMessage CONTAINS "\nzandy-")'
```

To follow one session:

```sh
log stream --level debug --predicate '(subsystem == "tbsklg.zandy" AND processID == <pid>) OR (senderImagePath ENDSWITH "/Sandbox" AND eventMessage MATCHES "(?s).*\nzandy-<pid>([^0-9].*)?")'
```

To follow one scope:

```sh
log stream --level debug --predicate 'subsystem == "tbsklg.zandy" AND category == "broker"'
```

Or look back at past sessions. macOS keeps everything except `debug` on disk for a few days:

```sh
log show --last 1h --predicate 'subsystem == "tbsklg.zandy" OR (senderImagePath ENDSWITH "/Sandbox" AND eventMessage CONTAINS "\nzandy-")'
```
