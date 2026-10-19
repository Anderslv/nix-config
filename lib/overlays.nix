{ inputs, allowUnfreePredicate }:

let
  # packages tracked on nixos-unstable-small instead of nixos-unstable
  fromSmall = [
    "t3code"
    "claude-code"
  ];
in
[
  (import ../overlays/tana.nix)
  inputs.flyline.overlays.default
  (import ../overlays/flyline-glibc-tls.nix)
  # legacyPackages would carry nixos-unstable-small's own config, dropping the
  # unfree predicate; re-import so both channels share it.
  (
    _: prev:
    inputs.nixpkgs.lib.getAttrs fromSmall (
      import inputs.nixpkgs-small {
        inherit (prev.stdenv.hostPlatform) system;
        config = { inherit allowUnfreePredicate; };
      }
    )
  )
  (import ../overlays/claude-code.nix)
]
