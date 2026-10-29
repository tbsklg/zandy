{
  inputs.zandy.url = "git+https://codeberg.org/tbsklg/zandy";
  inputs.nixpkgs.follows = "zandy/nixpkgs";

  outputs = { zandy, nixpkgs, ... }:
    let
      systems = [ "aarch64-darwin" ];
      forAllSystems = f: nixpkgs.lib.genAttrs systems (system: f (import nixpkgs {
        inherit system;
        config.allowUnfreePredicate = pkg: nixpkgs.lib.getName pkg == "claude-code";
      }));
    in
    {
      packages = forAllSystems (pkgs: {
        default = zandy.lib.mkSandboxEnv {
          inherit pkgs;
          name = "claude";
          preset = zandy.presets.claude;
          packages = [ pkgs.ripgrep ];
          gateway = zandy.gateways.bedrock { profile = "acme-bedrock"; region = "eu-west-1"; };
          adapters = [
            zandy.adapters.gitlab
            (zandy.adapters.aws { profiles = [ "acme-dev" ]; })
          ];
        };
      });
    };
}
