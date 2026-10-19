{ inputs, lib }:
{
  # Build with:
  # $ darwin-rebuild switch --flake .#example-host
  example-host = inputs.nix-darwin.lib.darwinSystem {
    specialArgs = { inherit inputs; };
    modules = [
      ./hosts/macmini
      {
        nixpkgs.overlays = lib.overlays;
      }
    ];
  };
}
