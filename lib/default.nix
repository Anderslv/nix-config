{ nixpkgs, inputs }:
let
  mkHomeConfig = import ./mkHomeConfig.nix { inherit inputs; };
  overlays = import ./overlays.nix { inherit inputs allowUnfreePredicate; };
  mkPkgs = import ./mkPkgs.nix { inherit inputs overlays allowUnfreePredicate; };
  forAllSystems =
    function:
    nixpkgs.lib.genAttrs [
      "x86_64-linux"
      "aarch64-linux"
      "aarch64-darwin"
    ] (system: function nixpkgs.legacyPackages.${system});
  allowUnfreePredicate =
    pkg:
    builtins.elem (pkg.pname or "") [
      "clockify"
      "zen-browser"
      "claude-code"
    ];
  generalPackages =
    pkgs: with pkgs; [
      yamllint
      marksman
      git-crypt
    ];
  # Home Manager package groups as a plain environment, for `nix shell` /
  # `nix develop` without activating Home Manager. Packages unavailable on the
  # target platform, directly or through a dependency (e.g. a script's
  # runtimeInputs), are dropped.
  mkUserEnv =
    system:
    let
      pkgs = mkPkgs system;
      packageSets = import ../home/modules/package-sets.nix {
        inherit pkgs system inputs;
        inherit (pkgs) lib;
        gui = false;
      };
      groups = [
        "core"
        "dev"
        "emacs"
        "scripts"
      ];
    in
    pkgs.buildEnv {
      name = "user-env";
      paths = builtins.filter (
        pkg:
        pkgs.lib.meta.availableOn pkgs.stdenv.hostPlatform pkg && (builtins.tryEval pkg.drvPath).success
      ) (pkgs.lib.concatMap (group: packageSets.${group}) groups);
      ignoreCollisions = true;
    };
in
{
  inherit
    mkHomeConfig
    mkPkgs
    mkUserEnv
    overlays
    forAllSystems
    generalPackages
    allowUnfreePredicate
    ;
}
