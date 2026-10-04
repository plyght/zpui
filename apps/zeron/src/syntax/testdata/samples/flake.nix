# comment
{ pkgs ? import <nixpkgs> { }, lib, ... }:
let
  version = "1.0";
  inherit (pkgs) stdenv;
  /* block */
  path = ./src;
in
stdenv.mkDerivation rec {
  pname = "zeron";
  inherit version;
  src = builtins.fetchurl { url = "https://example.com/${version}.tar.gz"; };
  buildPhase = ''
    make -j''${NIX_BUILD_CORES} all
  '';
  enable = true && !false || null == null;
  count = 1 + 2.5;
  meta = with lib; { license = licenses.mit; };
}
