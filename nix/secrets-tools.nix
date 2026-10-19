# Commands for the KeePassXC/sops-backed secrets (see docs/secrets.md).
# Shared by Home Manager and the flake's packages, so they can also be run
# with `nix run` on a machine that isn't set up yet.
{ pkgs, inputs }:
let
  nix-secrets-setup = pkgs.writeShellApplication {
    name = "nix-secrets-setup";
    runtimeInputs = with pkgs; [
      age
      coreutils
      diffutils
      git
      gnugrep
      jq
      keepassxc
      sops
    ];
    text = builtins.readFile ../scripts/secrets/setup.sh;
  };
in
{
  inherit nix-secrets-setup;

  # Runs dev/tests/secrets-setup.test.sh against the packaged command.
  secrets-setup-tests = pkgs.writeShellApplication {
    name = "secrets-setup-tests";
    runtimeInputs = with pkgs; [
      age
      bash
      coreutils
      diffutils
      git
      gnugrep
      gnused
      jq
      keepassxc
      sops
    ];
    runtimeEnv.SECRETS_SETUP = pkgs.lib.getExe nix-secrets-setup;
    text = builtins.readFile ../dev/tests/secrets-setup.test.sh;
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
