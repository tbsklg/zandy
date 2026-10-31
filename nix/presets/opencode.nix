{
  name = "opencode";
  binary = "opencode";
  packages = pkgs: [ pkgs.opencode pkgs.bash pkgs.coreutils pkgs.git ];
  env = [ "HOME" "TMPDIR" "USER" "TERM" "COLORTERM" "LANG" "LC_ALL" ];

  args = [ ];

  rules = [
    { action = "allow"; operation = "process_fork"; }
    { action = "allow"; operation = "sysctl_all"; }
    { action = "allow"; operation = "file_ioctl"; }
    { action = "allow"; operation = "file_read_metadata"; }
    { action = "allow"; operation = "process_info_all"; filter = { target = "same-sandbox"; }; }
    { action = "allow"; operation = "network_outbound"; filter = { remote_tcp = "*:443"; }; }
    { action = "allow"; operation = "network_outbound"; filter = { remote_unix_socket = { literal = "/private/var/run/mDNSResponder"; }; }; }
    { action = "allow"; operation = "network_outbound"; filter = { remote_unix_socket = { param = "BROKER_SOCK"; }; }; }
    { action = "allow"; operation = "system_socket"; filter = { socket_domain = "af_system"; }; }
    { action = "allow"; operation = "ipc_posix_shm_read_data"; }
    { action = "allow"; operation = "ipc_posix_shm_write_create"; }
    { action = "allow"; operation = "mach_lookup"; filter = { global_name = "com.apple.SecurityServer"; }; }
    { action = "allow"; operation = "mach_lookup"; filter = { global_name = "com.apple.securityd.xpc"; }; }
    { action = "allow"; operation = "mach_lookup"; filter = { global_name = "com.apple.bsd.dirhelper"; }; }
    { action = "allow"; operation = "mach_lookup"; filter = { global_name = "com.apple.logd"; }; }
    { action = "allow"; operation = "mach_lookup"; filter = { global_name = "com.apple.system.notification_center"; }; }
    { action = "allow"; operation = "mach_lookup"; filter = { global_name = "com.apple.system.opendirectoryd.libinfo"; }; }
    { action = "allow"; operation = "mach_lookup"; filter = { global_name = "com.apple.system.opendirectoryd.membership"; }; }
    { action = "allow"; operation = "mach_lookup"; filter = { global_name = "com.apple.PowerManagement.control"; }; }
    { action = "allow"; operation = "mach_lookup"; filter = { global_name = "com.apple.trustd.agent"; }; }
    { action = "allow"; operation = "file_all"; filter = { subpath = { param_append = { param = "HOME"; suffix = "/.local/share/opencode"; }; }; }; }
    { action = "allow"; operation = "file_all"; filter = { subpath = { param_append = { param = "HOME"; suffix = "/.local/state/opencode"; }; }; }; }
    { action = "allow"; operation = "file_all"; filter = { subpath = { param_append = { param = "HOME"; suffix = "/.cache/opencode"; }; }; }; }
    { action = "allow"; operation = "file_all"; filter = { subpath = { param_append = { param = "HOME"; suffix = "/.config/opencode"; }; }; }; }
    { action = "allow"; operation = "file_all"; filter = { subpath = { param_append = { param = "HOME"; suffix = "/dotfiles/config/opencode"; }; }; }; }
    { action = "deny"; operation = "file_write_all"; filter = { literal = { param_append = { param = "HOME"; suffix = "/.config/opencode/opencode.json"; }; }; }; }
    { action = "deny"; operation = "file_write_all"; filter = { subpath = { param_append = { param = "HOME"; suffix = "/.config/opencode/plugin"; }; }; }; }
    { action = "allow"; operation = "file_read_data"; filter = { literal = { param_append = { param = "HOME"; suffix = "/.gitconfig"; }; }; }; }
    { action = "allow"; operation = "file_read_data"; filter = { literal = { param_append = { param = "HOME"; suffix = "/.config/git/config"; }; }; }; }
    { action = "allow"; operation = "file_read_data"; filter = { literal = { param_append = { param = "HOME"; suffix = "/.config/git/ignore"; }; }; }; }
    { action = "allow"; operation = "file_read_data"; filter = { literal = { param_append = { param = "HOME"; suffix = "/.config/git/attributes"; }; }; }; }
    { action = "allow"; operation = "file_read_data"; filter = { subpath = { literal = "/usr/share/icu"; }; }; }
    { action = "allow"; operation = "file_read_data"; filter = { literal = { literal = "/"; }; }; }
    { action = "allow"; operation = "file_read_data"; filter = { subpath = { literal = "/private/etc/ssl"; }; }; }
    { action = "allow"; operation = "file_write_create"; filter = { subpath = { literal = "/private/tmp"; }; }; }
    { action = "allow"; operation = "file_read_data"; filter = { subpath = { literal = "/private/tmp"; }; }; }
    { action = "allow"; operation = "file_read_data"; filter = { subpath = { literal = "/private/var"; }; }; }
    { action = "allow"; operation = "file_write_data"; filter = { subpath = { param = "TMPDIR"; }; }; }
    { action = "allow"; operation = "file_write_create"; filter = { subpath = { param = "TMPDIR"; }; }; }
    { action = "allow"; operation = "file_read_data"; filter = { subpath = { literal = "/Library/Preferences"; }; }; }
    { action = "deny"; operation = "file_all"; filter = { subpath = { literal = "/private/tmp/com.apple.launchd"; }; }; }
    { action = "deny"; operation = "file_all"; filter = { subpath = { literal = "/private/var/db"; }; }; }
    { action = "deny"; operation = "file_all"; filter = { subpath = { literal = "/private/var/root"; }; }; }
    { action = "allow"; operation = "file_all"; filter = { subpath = { param = "CWD"; }; }; }
    { action = "allow"; operation = "file_all"; filter = { literal = { literal = "/dev/null"; }; }; }
    { action = "allow"; operation = "file_read_data"; filter = { literal = { literal = "/dev"; }; }; }
    { action = "allow"; operation = "file_read_data"; filter = { literal = { literal = "/dev/dtracehelper"; }; }; }
  ];
}
