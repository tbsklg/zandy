{ buildGoModule, fetchFromGitHub }:
buildGoModule rec {
  pname = "aws-sigv4-proxy";
  version = "1.13";
  src = fetchFromGitHub {
    owner = "awslabs";
    repo = "aws-sigv4-proxy";
    rev = "v${version}";
    hash = "sha256-RMLumWYHfxNxWt6UJzYvaAQX0PWltJrWcPZXrhrdymM=";
  };
  vendorHash = null;
  subPackages = [ "cmd/aws-sigv4-proxy" ];
  meta.mainProgram = "aws-sigv4-proxy";
}
