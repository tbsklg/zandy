{ zig-overlay }:
let
  zandyFor = pkgs: import ./zandy.nix {
    inherit pkgs;
    zig = zig-overlay.packages.${pkgs.stdenv.hostPlatform.system}."0.16.0";
  };

  mkSandboxEnv =
    { pkgs
    , name
    , preset
    , packages ? [ ]
    , adapters ? [ ]
    , policy ? { }
    , backend ? null
    , filesystem ? { }
    }:
    let
      inherit (pkgs) lib;
      inherit (zandyFor pkgs) zandy zandy-client;

      backendAdapters = lib.optional (backend ? bedrock) (import ./adapters/backend.nix backend.bedrock);
      resolvedAdapters = map (adapter: adapter pkgs) (adapters ++ backendAdapters);

      sandboxPackages = preset.packages pkgs ++ [ zandy-client ] ++ packages;
      clashes = builtins.filter (adapter: builtins.elem adapter.package sandboxPackages) resolvedAdapters;

      bin = pkgs.buildEnv {
        name = "${name}-bin";
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
        inherit policy filesystem;
      };
    in
    assert lib.assertMsg (clashes == [ ])
      "zandy: ${lib.concatMapStringsSep ", " (adapter: adapter.name) clashes} adapter packages must not be in packages; the broker runs them outside the sandbox";
    pkgs.runCommand name
      {
        manifest = builtins.toJSON manifest;
        passAsFile = [ "manifest" ];
        meta.mainProgram = "zandy-${name}";
      } ''
      mkdir -p $out/sandbox $out/bin
      ln -s ${bin}/bin $out/sandbox/bin
      cp ${closure}/store-paths $out/store-paths
      cp $manifestPath $out/zandy.json
      cat > $out/bin/zandy-${name} <<EOF
      #!/bin/sh
      exec ${zandy}/bin/zandy --env $out "\$@"
      EOF
      chmod +x $out/bin/zandy-${name}
    '';
in
{
  inherit mkSandboxEnv zandyFor;
}
