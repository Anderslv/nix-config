{
  config,
  inputs,
  lib,
  pkgs,
  ...
}:

let
  tools = import ../../nix/secrets-tools.nix { inherit pkgs inputs; };
  # Generated from KeePassXC by nix-secrets-setup; never part of the repo.
  secretsDir = "${config.home.homeDirectory}/.config/nix-secrets";
  secretNames = builtins.filter (
    line: line != "" && !lib.hasPrefix "#" line
  ) (lib.splitString "\n" (builtins.readFile ../../nix/secret-names.txt));
in

{
  options.customSecrets.enable = lib.mkEnableOption "sops-nix managed secrets (age + KeePassXC)";

  config = lib.mkIf config.customSecrets.enable {
    sops = {
      age.keyFile = "${config.home.homeDirectory}/.config/sops/age/keys.txt";
      # A string, not a path: Nix never reads or copies the file; sops-nix
      # decrypts it from disk at activation.
      defaultSopsFile = "${secretsDir}/secrets.yaml";
      validateSopsFiles = false;
      secrets = lib.genAttrs secretNames (_: { });
    };

    home.packages = [
      pkgs.age
      pkgs.sops
      # Pulled in unconditionally (not gated by customPackages.gui.enable):
      # keepassxc-cli is needed to set up secrets even on headless machines,
      # e.g. macmini.nix, which disables GUI packages.
      pkgs.keepassxc
      tools.nix-secrets-setup
    ]
    ++ lib.optional (tools ? darwin-switch) tools.darwin-switch;
  };
}
