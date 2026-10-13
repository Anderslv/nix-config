{
  pkgs,
  lib,
  config,
  system,
  inputs,
  ...
}:

let
  cfg = config.customPackages;
  packageSets = import ./package-sets.nix {
    inherit
      pkgs
      lib
      system
      inputs
      ;
    gui = cfg.gui.enable;
  };
in
{
  options.customPackages =
    lib.mapAttrs (name: packages: {
      enable = lib.mkEnableOption "${name} packages";
      packages = lib.mkOption {
        type = lib.types.listOf lib.types.package;
        default = packages;
        description = "${name} packages.";
      };
    }) packageSets
    // {
      gui.enable = lib.mkEnableOption "GUI packages, programs and services";
    };

  # Packages unavailable on the current platform (e.g. Linux-only tools on
  # darwin), directly or through a dependency, are dropped.
  config.home.packages =
    builtins.filter
      (pkg: lib.meta.availableOn pkgs.stdenv.hostPlatform pkg && (builtins.tryEval pkg.drvPath).success)
      (
        lib.concatMap (name: lib.optionals cfg.${name}.enable cfg.${name}.packages) (
          builtins.attrNames packageSets
        )
      );
}
