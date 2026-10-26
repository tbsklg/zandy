pkgs: {
  name = "gitlab";
  package = pkgs.glab;
  binary = "glab";
  env = [ "GITLAB_TOKEN" ];
  capabilities = [
    {
      name = "cli";
      description = "Run a glab command with the broker's GITLAB_TOKEN. What it may do is decided by the token's scopes. args are the glab arguments, e.g. [\"issue\", \"list\", \"--repo\", \"group/name\"].";
      effect = "admin";
      params = [
        { name = "args"; kind = "list"; description = "Arguments passed to glab, one entry per argument"; }
      ];
      argv = [ "{args}" ];
    }
  ];
}
