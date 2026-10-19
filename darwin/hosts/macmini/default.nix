{
  inputs,
  lib,
  pkgs,
  username,
  ...
}:

{
  imports = [ inputs.home-manager.darwinModules.home-manager ];

  system.primaryUser = username;
  users.users.${username}.home = "/Users/${username}";

  # Home Manager runs as part of darwin-rebuild, with the same profile the
  # Linux machines use (home/common.nix) plus the macOS overrides.
  home-manager = {
    useGlobalPkgs = true;
    useUserPackages = true;
    backupFileExtension = "hm-backup";
    extraSpecialArgs = {
      inherit inputs;
      inherit (pkgs.stdenv.hostPlatform) system;
    };
    users.${username} = {
      imports = [
        ../../../home/common.nix
        ../../../home/systems/macmini.nix
      ];
      # home/common.nix sets nixpkgs.config for standalone Home Manager;
      # here pkgs come from nix-darwin, which rejects HM-level nixpkgs options.
      nixpkgs.config = lib.mkForce null;
    };
  };

  # System-wide packages. Anything Home Manager already provides (btop,
  # direnv, nix-direnv, tmux, uv) is left to home/modules instead.
  environment.systemPackages = with pkgs; [
    air-formatter
    colima
    htop
    hunk
    jdk17
    lazygit
    libreoffice-bin
    neovim
    nixfmt
    positron-bin
    pymol
    stow
    superfile
    worktrunk
  ];

  system.activationScripts.postActivation.text = ''
    if ! /usr/bin/pgrep -q oahd; then
      echo "Installing Rosetta 2..."
      /usr/sbin/softwareupdate --install-rosetta --agree-to-license
    fi
  '';

  nix.settings = {
    experimental-features = "nix-command flakes";
    extra-substituters = [ "https://rstats-on-nix.cachix.org" ];
    extra-trusted-public-keys = [
      "rstats-on-nix.cachix.org-1:vdiiVgocg6WeJrODIqdprZRUrhi1JzhBnXv7aWI6+F0="
    ];
  };

  nixpkgs.config.allowUnfree = true;
  nixpkgs.hostPlatform = "aarch64-darwin";

  # Set Git commit hash for darwin-version.
  system.configurationRevision = inputs.self.rev or inputs.self.dirtyRev or null;

  # Used for backwards compatibility, please read the changelog before changing.
  # $ darwin-rebuild changelog
  system.stateVersion = 6;

  system.defaults = {
    dock.autohide = false;
    dock.mru-spaces = false;
    finder.AppleShowAllExtensions = true;
    finder.FXPreferredViewStyle = "clmv";
    screencapture.location = "~/Pictures/screenshots";
    screensaver.askForPasswordDelay = 0;
  };
}
