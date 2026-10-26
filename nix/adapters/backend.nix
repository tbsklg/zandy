{ profile, ... }: pkgs: {
  name = "backend";
  package = pkgs.awscli2;
  binary = "aws";
  capabilities = [
    {
      name = "credentials";
      description = "Short-lived AWS credentials for Bedrock, used by Claude Code's awsCredentialExport.";
      effect = "read";
      argv = [ "configure" "export-credentials" "--profile" profile "--format" "process" ];
    }
  ];
}
