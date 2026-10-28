let
  zandyFor = pkgs: import ./zandy.nix { inherit pkgs; };

  mkSandboxEnv = { pkgs, ... }@args:
    let
      inherit (pkgs) lib;

      cfg = (lib.evalModules {
        modules = [ ./options.nix (builtins.removeAttrs args [ "pkgs" ]) ];
      }).config;
      inherit (cfg) preset;
      inherit (zandyFor pkgs) zandy zandy-client;

      resolvedAdapters = map (adapter: adapter pkgs) cfg.adapters;
      gateway = if cfg.gateway == null then null else cfg.gateway pkgs;

      gatewayEnv =
        let
          vars = if gateway == null then { } else preset.gatewayEnv.${gateway.name} or { };
          resolved = if lib.isFunction vars then vars gateway else vars;
        in
        lib.mapAttrsToList (name: value: { gateway = gateway.name; inherit name value; }) resolved;

      sandboxPackages = preset.packages pkgs ++ [ zandy-client ] ++ cfg.packages;
      clashes = builtins.filter (adapter: builtins.elem adapter.package sandboxPackages) resolvedAdapters;

      bin = pkgs.buildEnv {
        name = "${cfg.name}-bin";
        paths = sandboxPackages;
      };
      closure = pkgs.closureInfo { rootPaths = [ bin ]; };

      manifest = {
        preset = {
          inherit (preset) name binary env args;
          inherit gatewayEnv;
          profile.rules = preset.rules;
        };
        adapters = map
          (adapter: {
            inherit (adapter) name capabilities;
            binary = "${adapter.package}/bin/${adapter.binary}";
            env = adapter.env or [ ];
          })
          resolvedAdapters;
        gateway = if gateway == null then null else { inherit (gateway) name upstream auth; };
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
