# Commands for the KeePassXC/sops-backed secrets (see docs/secrets.md).
# Shared by Home Manager and the flake's packages, so they can also be run
# with `nix run` on a machine that isn't set up yet.
{ pkgs, inputs }:
{
  nix-secrets-setup = pkgs.writeShellApplication {
    name = "nix-secrets-setup";
    runtimeInputs = with pkgs; [
      age
      coreutils
      diffutils
      git
      gnugrep
      keepassxc
      sops
    ];
    text = builtins.readFile ../scripts/secrets/setup.sh;
  };
}
// pkgs.lib.optionalAttrs pkgs.stdenv.hostPlatform.isDarwin {
  darwin-switch = pkgs.writeShellApplication {
    name = "darwin-switch";
    runtimeInputs = [
      inputs.nix-darwin.packages.${pkgs.stdenv.hostPlatform.system}.darwin-rebuild
      pkgs.git
      pkgs.sops
    ];
    text = builtins.readFile ../bin/darwin-switch;
  };
}
