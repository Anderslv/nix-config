{ inputs, ... }:
{
  system,
  username,
  homeDirectory,
  extraModules ? [ ],
  lib,
}:

inputs.home-manager.lib.homeManagerConfiguration {
  pkgs = lib.mkPkgs system;
  modules = [
    ../home/common.nix
    {
      home.username = username;
      home.homeDirectory = homeDirectory;
    }
  ]
  ++ extraModules;
  extraSpecialArgs = { inherit inputs system; };
}
