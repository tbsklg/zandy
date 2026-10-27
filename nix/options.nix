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
          settings = mkOption { type = types.functionTo types.raw; default = _: null; description = "App settings, given `backend`."; };
          args = mkOption { type = types.functionTo (types.listOf types.str); default = _: [ ]; description = "Startup args, given `{ settings }`."; };
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

    backend.bedrock = mkOption {
      type = types.nullOr (types.submodule {
        options = {
          profile = mkOption { type = types.str; description = "AWS profile the broker exports Bedrock credentials from."; };
          region = mkOption { type = types.str; description = "AWS region of Bedrock."; };
        };
      });
      default = null;
      description = "Run the model through Amazon Bedrock; the credentials come from the broker.";
      example = { profile = "acme-bedrock"; region = "eu-west-1"; };
    };

    filesystem = {
      allowRead = paths "Extra paths the agent may read.";
      denyRead = paths "Paths the agent may not read.";
      allowWrite = paths "Extra paths the agent may write.";
      denyWrite = paths "Paths the agent may not write.";
    };
  };
}
