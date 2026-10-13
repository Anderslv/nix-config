{
  config,
  lib,
  pkgs,
  ...
}:

{
  options.customSecrets.enable = lib.mkEnableOption "sops-nix managed secrets (age + KeePassXC)";

  config = lib.mkIf config.customSecrets.enable {
    sops = {
      age.keyFile = "${config.home.homeDirectory}/.config/sops/age/keys.txt";
      defaultSopsFile = ../../secrets/secrets.yaml;
      # The default sops file may not exist yet on a fresh checkout (see
      # docs/secrets.md); only declared `sops.secrets.*` entries actually
      # need it to resolve, so don't fail eval just because it's missing.
      validateSopsFiles = false;
    };

    home.packages = [
      pkgs.age
      pkgs.sops
      # Pulled in unconditionally (not gated by customPackages.gui.enable):
      # keepassxc-cli is needed to bootstrap the age identity even on
      # headless machines, e.g. macmini.nix, which disables GUI packages.
      pkgs.keepassxc
      (pkgs.writeShellApplication {
        name = "sops-age-bootstrap";
        runtimeInputs = [
          pkgs.age
          pkgs.coreutils
          pkgs.keepassxc
        ];
        text = builtins.readFile ../../scripts/secrets/bootstrap-age-key.sh;
      })
    ];
  };
}
