{ profile, region }: pkgs:
let
  proxy = pkgs.callPackage ../packages/aws-sigv4-proxy.nix { };
in
{
  name = "bedrock";
  inherit region;
  argv = [ "${proxy}/bin/aws-sigv4-proxy" "--port" "127.0.0.1:{port}" "--name" "bedrock" "--region" region "--host" "bedrock-runtime.${region}.amazonaws.com" "--upstream-url-scheme" "https" ];
  env.AWS_PROFILE = profile;
}
