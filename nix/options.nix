{ lib, ... }:
let
  inherit (lib) mkOption types;
  paths = description: mkOption {
    type = types.listOf types.str;
    default = [ ];
    description = "${description} Absolute, relative to the working directory, or starting with `~`.";
  };
in
{
  options = {
    name = mkOption {
      type = types.strMatching "[a-z0-9-]+";
      description = "Name of the sandbox env; the launcher becomes `bin/zandy-<name>`.";
      example = "claude";
    };

    preset = mkOption {
      description = "The app to run and the sandbox rules it needs, e.g. `zandy.presets.claude`.";
      type = types.submodule {
        options = {
          name = mkOption { type = types.str; description = "Name of the preset."; };
          binary = mkOption { type = types.str; description = "Binary in `sandbox/bin` to execute."; };
          packages = mkOption { type = types.functionTo (types.listOf types.package); description = "Packages the app needs, given `pkgs`."; };
          env = mkOption { type = types.listOf types.str; default = [ ]; description = "Names of the environment variables passed into the sandbox."; };
          args = mkOption { type = types.listOf types.str; default = [ ]; description = "Startup args."; };
          gatewayEnv = mkOption { type = types.attrsOf (types.either (types.attrsOf types.str) (types.functionTo (types.attrsOf types.str))); default = { }; description = "Env vars the app gets per gateway name, or a function of the gateway; `{url}` becomes the gateway's address."; };
          rules = mkOption { type = types.listOf types.attrs; description = "SBPL rules the app needs."; };
        };
      };
    };

    packages = mkOption {
      type = types.listOf types.package;
      default = [ ];
      description = "Extra packages on the sandbox `PATH`, e.g. the project's toolchain.";
      example = lib.literalExpression "[ pkgs.ripgrep ]";
    };

    adapters = mkOption {
      type = types.listOf (types.functionTo types.attrs);
      default = [ ];
      description = "Tools the broker runs outside the sandbox on the agent's behalf. Their packages must not be in `packages`.";
      example = lib.literalExpression ''[ zandy.adapters.gitlab (zandy.adapters.aws { profiles = [ "acme-dev" ]; }) ]'';
    };

    gateways = mkOption {
      type = types.listOf (types.functionTo types.attrs);
      default = [ ];
      description = "Model backends the broker forwards to, adding auth outside the sandbox.";
      example = lib.literalExpression ''[ (zandy.gateways.bedrock { profile = "acme-bedrock"; region = "eu-west-1"; }) ]'';
    };


    filesystem = {
      allowRead = paths "Extra paths the agent may read.";
      denyRead = paths "Paths the agent may not read.";
      allowWrite = paths "Extra paths the agent may write.";
      denyWrite = paths "Paths the agent may not write.";
    };
  };
}
