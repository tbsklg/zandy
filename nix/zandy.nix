{ pkgs, zig }:
let
  zandy = pkgs.stdenvNoCC.mkDerivation {
    pname = "zandy";
    version = "0.0.8";
    src = pkgs.lib.fileset.toSource {
      root = ../.;
      fileset = pkgs.lib.fileset.unions [ ../build.zig ../build.zig.zon ../src ];
    };
    nativeBuildInputs = [ zig pkgs.removeReferencesTo ];
    buildPhase = ''
      export ZIG_GLOBAL_CACHE_DIR=$TMPDIR/zig-cache
      zig build -Doptimize=ReleaseSafe --prefix $out
    '';
    dontInstall = true;
    postFixup = ''
      remove-references-to -t ${zig} $out/bin/*
    '';
    disallowedReferences = [ zig ];
  };

  zandy-client = pkgs.runCommand "zandy-client" { } ''
    mkdir -p $out/bin
    cp ${zandy}/bin/zandy-client $out/bin/
  '';
in
{
  inherit zandy zandy-client;
}
