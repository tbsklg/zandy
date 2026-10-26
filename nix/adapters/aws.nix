{ profiles }: pkgs: {
  name = "aws";
  package = pkgs.awscli2;
  binary = "aws";
  capabilities = [
    {
      name = "cli";
      description = "Run an AWS CLI command with one of the configured profiles. What it may do is decided by the profile's IAM permissions. args are the aws arguments, e.g. [\"s3api\", \"list-buckets\"].";
      effect = "admin";
      params = [
        { name = "profile"; kind = "choice"; choices = profiles; description = "AWS profile to run the command with"; }
        { name = "args"; kind = "list"; description = "Arguments passed to aws, one entry per argument"; }
      ];
      argv = [ "{args}" "--profile" "{profile}" ];
    }
  ];
}
