{ inputs, lib }:
let
  # Kept out of the repo: darwin-switch decrypts them from secrets/host.yaml
  # and passes them in, so they are only visible with --impure.
  username = builtins.getEnv "NIX_CONFIG_USERNAME";
  hostname = builtins.getEnv "NIX_CONFIG_HOSTNAME";
in
inputs.nixpkgs.lib.optionalAttrs (username != "" && hostname != "") {
  # Build with:
  # $ darwin-switch
  ${hostname} = inputs.nix-darwin.lib.darwinSystem {
    specialArgs = { inherit inputs username; };
    modules = [
      ./hosts/macmini
      {
        nixpkgs.overlays = lib.overlays;
      }
    ];
  };
}
