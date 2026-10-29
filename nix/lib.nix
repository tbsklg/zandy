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
        gateway = if gateway == null then null else { inherit (gateway) name argv; env = gateway.env or { }; secrets = gateway.secrets or { }; };
        inherit (cfg) filesystem;
      };

      env = pkgs.linkFarm "${cfg.name}-env" [
        { name = "sandbox/bin"; path = "${bin}/bin"; }
        { name = "store-paths"; path = "${closure}/store-paths"; }
        { name = "zandy.json"; path = (pkgs.formats.json { }).generate "zandy.json" manifest; }
      ];

      launcher = pkgs.writeShellApplication {
        name = "zandy-${cfg.name}";
        text = ''exec ${zandy}/bin/zandy --env ${env} "$@"'';
      };
    in
    assert lib.assertMsg pkgs.stdenv.hostPlatform.isDarwin
      "zandy: macOS only, ${pkgs.stdenv.hostPlatform.system} is not supported";
    assert lib.assertMsg (clashes == [ ])
      "zandy: ${lib.concatMapStringsSep ", " (adapter: adapter.name) clashes} adapter packages must not be in packages; the broker runs them outside the sandbox";
    pkgs.symlinkJoin {
      name = cfg.name;
      paths = [ env launcher ];
      meta.mainProgram = "zandy-${cfg.name}";
    };
in
{
  inherit mkSandboxEnv zandyFor;
}
