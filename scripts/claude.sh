#!/bin/sh
exec /usr/bin/sandbox-exec -D "CWD=$PWD" -D "HOME=$HOME" -p '
(version 1)
(deny default)

(allow process-exec)
(allow process-fork)
(allow sysctl*)
(allow file-ioctl)
(allow file-read-metadata)
(allow file-map-executable)
(allow process-info* (target same-sandbox))
(allow signal (target same-sandbox))
(allow mach-priv-task-port (target same-sandbox))

; Network
(allow network-outbound)
(allow system-socket (socket-domain 32))

; Mach services
(allow mach-lookup (global-name "com.apple.bsd.dirhelper"))
(allow mach-lookup (global-name "com.apple.logd"))
(allow mach-lookup (global-name "com.apple.PowerManagement.control"))
(allow mach-lookup (global-name "com.apple.system.notification_center"))
(allow mach-lookup (global-name "com.apple.system.opendirectoryd.libinfo"))
(allow mach-lookup (global-name "com.apple.system.opendirectoryd.membership"))
(allow mach-lookup (global-name "com.apple.SecurityServer"))
(allow mach-lookup (global-name "com.apple.securityd.xpc"))

; https://github.com/anthropics/claude-code/issues/34876
(allow mach-lookup (global-name "com.apple.trustd"))

(allow mach-lookup (global-name "ipc-posix-shm-read-data apple.shm.notification_center"))

; Claude config
(allow file* (subpath (string-append (param "HOME") "/.claude")))
(allow file* (literal (string-append (param "HOME") "/.claude.json")))
(allow file* (literal (string-append (param "HOME") "/.claude.json.lock")))

(allow file-read* (literal (string-append (param "HOME") "/.aws/credentials")))
(allow file-read* (literal (string-append (param "HOME") "/.aws/config")))
(allow file-read* (subpath (string-append (param "HOME") "/.aws/sso/cache")))

(allow file-read-data (subpath "/opt/homebrew"))

(allow file-read-data (subpath "/usr/share/icu"))

; CWD
(allow file* (subpath (param "CWD")))

(allow file* (literal "/dev/null"))

(allow file-read-data (literal "/"))

(allow file-read-data (subpath "/private/var"))
(allow file-write* (subpath "/private/var"))

(allow file-read-data (subpath "/private/tmp"))
(allow file-write* (subpath "/private/tmp"))

(deny file* (subpath "/private/tmp/com.apple.launchd"))
' claude "$@"
