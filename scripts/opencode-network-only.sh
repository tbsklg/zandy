#!/bin/sh

TARGET_DIR="/tmp/zandy"

mkdir -p "$TARGET_DIR"

exec /usr/bin/sandbox-exec -D "HOME=$HOME" -D "CWD=$PWD" -p '
(version 1)
(deny default)

; Process
(allow process-exec)
(allow process-fork)
(allow sysctl*)
(allow file-ioctl)
(allow file-read-metadata)
(allow file-map-executable)

; Network
(allow network-outbound)
(allow system-socket (socket-domain 32))

; Mach services
(allow mach-lookup (global-name "com.apple.SecurityServer"))
(allow mach-lookup (global-name "com.apple.securityd.xpc"))
(allow mach-lookup (global-name "com.apple.bsd.dirhelper"))
(allow mach-lookup (global-name "com.apple.logd"))
(allow mach-lookup (global-name "com.apple.system.notification_center"))
(allow mach-lookup (global-name "com.apple.system.opendirectoryd.libinfo"))
(allow mach-lookup (global-name "com.apple.system.opendirectoryd.membership"))
(allow mach-lookup (global-name "com.apple.PowerManagement.control"))
(allow mach-lookup (global-name "ipc-posix-shm-read-data apple.shm.notification_center"))

; Opencode Config
(allow file* (subpath (string-append (param "HOME") "/.local/share/opencode")))
(allow file* (subpath (string-append (param "HOME") "/.local/state/opencode")))
(allow file* (subpath (string-append (param "HOME") "/.cache/opencode")))
(allow file* (subpath (string-append (param "HOME") "/.config/opencode")))
(allow file* (subpath (string-append (param "HOME") "/dotfiles/config/opencode")))

; CWD
(allow file-read* (subpath (param "CWD")))

(allow file-read-data (subpath "/opt/homebrew"))

(allow file-read-data (subpath "/private/var"))
(allow file-read-data (subpath "/usr/share/icu"))

(allow file* (literal "/dev/null"))
(allow file-read-data (literal "/"))
(allow file-read-data (subpath "/private/tmp"))
(allow file-write-data (subpath "/private/var"))
(allow file-write-create (subpath "/private/var"))

(deny file* (subpath "/private/tmp/com.apple.launchd"))
' opencode "$TARGET_DIR" "$@"
