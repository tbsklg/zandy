{
  description = "zandy";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { nixpkgs, flake-utils, ... }:
    let
      lib = import ./nix/lib.nix;
    in
    {
      lib = { inherit (lib) mkSandboxEnv; };

      presets = {
        claude = import ./nix/presets/claude.nix;
        opencode = import ./nix/presets/opencode.nix;
      };

      adapters = {
        gitlab = import ./nix/adapters/gitlab.nix;
        aws = import ./nix/adapters/aws.nix;
      };

      gateways = {
        bedrock = import ./nix/gateways/bedrock.nix;
        anthropic = import ./nix/gateways/anthropic.nix;
        openai = import ./nix/gateways/openai.nix;
      };

      templates.default = {
        path = ./templates/default;
        description = "A zandy sandbox env: run with `nix run`, install with `nix profile add`";
      };
    }
    // flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = import nixpkgs {
          inherit system;
          config.allowUnfreePredicate = pkg: builtins.elem (nixpkgs.lib.getName pkg) [ "claude-code" ];
        };
        inherit (lib.zandyFor pkgs) zig zandy zandy-client tests;
      in
      {
        packages = {
          inherit zandy zandy-client;
          options-doc = (pkgs.nixosOptionsDoc {
            options = builtins.removeAttrs (pkgs.lib.evalModules { modules = [ ./nix/options.nix ]; }).options [ "_module" ];
            transformOptions = opt: opt // { declarations = [ ]; };
          }).optionsCommonMark;
          default = lib.mkSandboxEnv {
            inherit pkgs;
            name = "demo";
            preset = import ./nix/presets/claude.nix;
            packages = [ pkgs.ripgrep ];
            gateway = import ./nix/gateways/bedrock.nix { profile = "acme-bedrock"; region = "eu-west-1"; };
            adapters = [
              (import ./nix/adapters/gitlab.nix)
              (import ./nix/adapters/aws.nix { profiles = [ "acme-dev" ]; })
            ];
          };
        };

        checks = { inherit tests; };

        devShells.default = pkgs.mkShell {
          packages = [ zig ];
        };
      });
}
