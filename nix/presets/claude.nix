let
  prompt = ''
    You run inside the zandy sandbox. CLIs like aws and glab have no credentials here.
    Run `zandy-client discover` to list the available broker methods, then call one with
    `zandy-client call <method> '<json args>'`, e.g.
    `zandy-client call aws.cli '{"profile":"<profile>","args":["s3","ls"]}'`.
  '';
in
{
  name = "claude";
  binary = "claude";
  packages = pkgs: [ pkgs.claude-code pkgs.bash pkgs.coreutils pkgs.git ];
  env = [ "HOME" "TMPDIR" "USER" "TERM" "COLORTERM" "LANG" "LC_ALL" ];

  gatewayEnv = {
    anthropic = {
      ANTHROPIC_BASE_URL = "{url}";
      ANTHROPIC_AUTH_TOKEN = "zandy-gateway";
    };
    bedrock = gateway: {
      CLAUDE_CODE_USE_BEDROCK = "1";
      CLAUDE_CODE_SKIP_BEDROCK_AUTH = "1";
      ANTHROPIC_BEDROCK_BASE_URL = "{url}";
      AWS_REGION = gateway.region;
    };
  };

  args = [ "--append-system-prompt" prompt ];

  rules = [
    { action = "allow"; operation = "process_exec"; filter = { literal = { literal = "/bin/sh"; }; }; }
    { action = "allow"; operation = "process_exec"; filter = { literal = { literal = "/bin/bash"; }; }; }
    { action = "allow"; operation = "process_fork"; }
    { action = "allow"; operation = "sysctl_all"; }
    { action = "allow"; operation = "file_ioctl"; }
    { action = "allow"; operation = "file_read_metadata"; }
    { action = "allow"; operation = "file_map_executable"; }
    { action = "allow"; operation = "process_info_all"; filter = { target = "same-sandbox"; }; }
    { action = "allow"; operation = "signal"; filter = { target = "same-sandbox"; }; }
    { action = "allow"; operation = "mach_priv_task_port"; filter = { target = "same-sandbox"; }; }
    { action = "allow"; operation = "network_outbound"; filter = { remote_tcp = "*:443"; }; }
    { action = "allow"; operation = "network_outbound"; filter = { remote_unix_socket = { literal = "/private/var/run/mDNSResponder"; }; }; }
    { action = "allow"; operation = "network_outbound"; filter = { remote_unix_socket = { param = "BROKER_SOCK"; }; }; }
    { action = "allow"; operation = "system_socket"; filter = { socket_domain = "af_system"; }; }
    { action = "allow"; operation = "mach_lookup"; filter = { global_name = "com.apple.bsd.dirhelper"; }; }
    { action = "allow"; operation = "mach_lookup"; filter = { global_name = "com.apple.logd"; }; }
    { action = "allow"; operation = "mach_lookup"; filter = { global_name = "com.apple.PowerManagement.control"; }; }
    { action = "allow"; operation = "mach_lookup"; filter = { global_name = "com.apple.system.notification_center"; }; }
    { action = "allow"; operation = "mach_lookup"; filter = { global_name = "com.apple.system.opendirectoryd.libinfo"; }; }
    { action = "allow"; operation = "mach_lookup"; filter = { global_name = "com.apple.system.opendirectoryd.membership"; }; }
    { action = "allow"; operation = "mach_lookup"; filter = { global_name = "com.apple.SecurityServer"; }; }
    { action = "allow"; operation = "mach_lookup"; filter = { global_name = "com.apple.securityd.xpc"; }; }
    # https://github.com/anthropics/claude-code/issues/34876
    { action = "allow"; operation = "mach_lookup"; filter = { global_name = "com.apple.trustd"; }; }
    { action = "allow"; operation = "file_all"; filter = { subpath = { param_append = { param = "HOME"; suffix = "/.claude"; }; }; }; }
    { action = "allow"; operation = "file_all"; filter = { literal = { param_append = { param = "HOME"; suffix = "/.claude.json"; }; }; }; }
    { action = "allow"; operation = "file_all"; filter = { literal = { param_append = { param = "HOME"; suffix = "/.claude.json.lock"; }; }; }; }
    { action = "deny"; operation = "file_write_all"; filter = { literal = { param_append = { param = "HOME"; suffix = "/.claude/settings.json"; }; }; }; }
    { action = "deny"; operation = "file_write_all"; filter = { literal = { param_append = { param = "HOME"; suffix = "/.claude/settings.local.json"; }; }; }; }
    { action = "deny"; operation = "file_write_all"; filter = { subpath = { param_append = { param = "HOME"; suffix = "/.claude/plugins"; }; }; }; }
    { action = "allow"; operation = "file_write_all"; filter = { literal = { param_append = { param = "HOME"; suffix = "/Library/Caches/claude-cli-nodejs"; }; }; }; }
    { action = "allow"; operation = "file_read_data"; filter = { subpath = { literal = "/usr/share/icu"; }; }; }
    { action = "allow"; operation = "file_all"; filter = { subpath = { param = "CWD"; }; }; }
    { action = "allow"; operation = "file_all"; filter = { literal = { literal = "/dev/null"; }; }; }
    { action = "allow"; operation = "file_read_data"; filter = { literal = { literal = "/"; }; }; }
    { action = "allow"; operation = "file_read_data"; filter = { subpath = { literal = "/private/var"; }; }; }
    { action = "allow"; operation = "file_write_all"; filter = { subpath = { param = "TMPDIR"; }; }; }
    { action = "allow"; operation = "file_read_data"; filter = { subpath = { literal = "/private/tmp"; }; }; }
    { action = "allow"; operation = "file_write_all"; filter = { subpath = { literal = "/private/tmp"; }; }; }
    { action = "deny"; operation = "file_all"; filter = { subpath = { literal = "/private/tmp/com.apple.launchd"; }; }; }
    { action = "deny"; operation = "file_all"; filter = { subpath = { literal = "/private/var/db"; }; }; }
    { action = "deny"; operation = "file_all"; filter = { subpath = { literal = "/private/var/root"; }; }; }
  ];
}
