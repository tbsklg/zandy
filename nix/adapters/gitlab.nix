{ host ? "gitlab.com", service ? "gitlab-token" }: pkgs: {
  name = "gitlab";
  package = pkgs.glab;
  binary = "glab";
  secrets.GITLAB_TOKEN.keychain = { inherit service; };
  files."config.yml" = ''
    hosts:
      ${host}:
        token: {secret.GITLAB_TOKEN}
  '';
  setEnv = {
    GLAB_CONFIG_DIR = "{dir}";
    GITLAB_HOST = host;
    GLAB_SHOW_WHATS_NEW = "false";
    GLAB_CHECK_UPDATE = "false";
  };
  capabilities = [
    {
      name = "cli";
      description = "Run a glab command with the broker's GitLab token. What it may do is decided by the token's scopes. args are the glab arguments, e.g. [\"issue\", \"list\", \"--repo\", \"group/name\"].";
      params = [
        { name = "args"; kind = "list"; description = "Arguments passed to glab, one entry per argument"; }
      ];
      argv = [ "{args}" ];
    }
  ];
}
