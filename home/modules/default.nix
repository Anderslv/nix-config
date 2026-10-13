{ inputs, ... }:

{
  imports = [
    inputs.waytorandr.homeManagerModules.default
    inputs.sops-nix.homeManagerModules.sops
    ./dotfiles.nix
    ./packages.nix
    ./programs.nix
    ./secrets.nix
    ./services.nix
  ];
}
