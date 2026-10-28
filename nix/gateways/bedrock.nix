{ profile, region }: pkgs:
let
  host = "bedrock-runtime.${region}.amazonaws.com";
  proxy = pkgs.callPackage ../packages/aws-sigv4-proxy.nix { };
in
{
  name = "bedrock";
  inherit region;
  upstream = "https://${host}";
  # aws-sigv4-proxy signs each request with the profile's credentials, outside the sandbox.
  auth.proxy = {
    argv = [ "${proxy}/bin/aws-sigv4-proxy" "--port" "127.0.0.1:{port}" "--name" "bedrock" "--region" region "--host" host "--upstream-url-scheme" "https" ];
    env.AWS_PROFILE = profile;
  };
}
