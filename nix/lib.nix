{ zig-overlay }:
let
  zandyFor = pkgs: import ./zandy.nix {
    inherit pkgs;
    zig = zig-overlay.packages.${pkgs.stdenv.hostPlatform.system}."0.16.0";
  };

  mkSandboxEnv = { pkgs, ... }@args:
    let
      inherit (pkgs) lib;

      cfg = (lib.evalModules {
        modules = [ ./options.nix (builtins.removeAttrs args [ "pkgs" ]) ];
      }).config;
      inherit (cfg) preset backend;
      inherit (zandyFor pkgs) zandy zandy-client;

      backendAdapters = lib.optional (backend.bedrock != null) (import ./adapters/backend.nix backend.bedrock);
      resolvedAdapters = map (adapter: adapter pkgs) (cfg.adapters ++ backendAdapters);

      sandboxPackages = preset.packages pkgs ++ [ zandy-client ] ++ cfg.packages;
      clashes = builtins.filter (adapter: builtins.elem adapter.package sandboxPackages) resolvedAdapters;

      bin = pkgs.buildEnv {
        name = "${cfg.name}-bin";
        paths = sandboxPackages;
      };
      closure = pkgs.closureInfo { rootPaths = [ bin ]; };

      manifest = {
        preset = {
          inherit (preset) name binary env;
          args = preset.args { settings = preset.settings backend; };
          profile.rules = preset.rules;
        };
        adapters = map
          (adapter: {
            inherit (adapter) name capabilities;
            binary = "${adapter.package}/bin/${adapter.binary}";
            env = adapter.env or [ ];
          })
          resolvedAdapters;
        inherit (cfg) filesystem;
      };
    in
    assert lib.assertMsg (clashes == [ ])
      "zandy: ${lib.concatMapStringsSep ", " (adapter: adapter.name) clashes} adapter packages must not be in packages; the broker runs them outside the sandbox";
    pkgs.runCommand cfg.name
      {
        manifest = builtins.toJSON manifest;
        passAsFile = [ "manifest" ];
        meta.mainProgram = "zandy-${cfg.name}";
      } ''
      mkdir -p $out/sandbox $out/bin
      ln -s ${bin}/bin $out/sandbox/bin
      cp ${closure}/store-paths $out/store-paths
      cp $manifestPath $out/zandy.json
      cat > $out/bin/zandy-${cfg.name} <<EOF
      #!/bin/sh
      exec ${zandy}/bin/zandy --env $out "\$@"
      EOF
      chmod +x $out/bin/zandy-${cfg.name}
    '';
in
{
  inherit mkSandboxEnv zandyFor;
}
