{ pkgs }:
let
  zig = pkgs.zig_0_16;

  zandy = pkgs.stdenvNoCC.mkDerivation {
    pname = "zandy";
    version = "0.0.8";
    src = pkgs.lib.fileset.toSource {
      root = ../.;
      fileset = pkgs.lib.fileset.unions [ ../build.zig ../build.zig.zon ../src ];
    };
    nativeBuildInputs = [ zig.hook pkgs.removeReferencesTo ];
    postFixup = ''
      remove-references-to -t ${zig} $out/bin/*
    '';
    disallowedReferences = [ zig ];
  };

  tests = zandy.overrideAttrs {
    pname = "zandy-tests";
    doCheck = true;
    __darwinAllowLocalNetworking = true;
  };

  zandy-client = pkgs.runCommand "zandy-client" { } ''
    mkdir -p $out/bin
    cp ${zandy}/bin/zandy-client $out/bin/
  '';
in
{
  inherit zig zandy zandy-client tests;
}
