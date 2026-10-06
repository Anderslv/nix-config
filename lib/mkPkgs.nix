{ inputs, allowUnfreePredicate }:
system:

let
  # packages tracked on nixos-unstable-small instead of nixos-unstable
  fromSmall = [
    "t3code"
    "claude-code"
  ];
  config = { inherit allowUnfreePredicate; };
  # legacyPackages would carry nixos-unstable-small's own config, dropping the
  # unfree predicate; re-import so both channels share it.
  smallPkgs = import inputs.nixpkgs-small { inherit system config; };
in
import inputs.nixpkgs {
  inherit system config;
  overlays = [
    (import ../overlays/tana.nix)
    inputs.flyline.overlays.default
    (import ../overlays/flyline-glibc-tls.nix)
    (_: _: inputs.nixpkgs.lib.getAttrs fromSmall smallPkgs)
    (import ../overlays/claude-code.nix)
  ];
}
