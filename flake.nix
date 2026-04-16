{
  description = "Minimal NixOS WSL2 image";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs = { self, nixpkgs }:
    let
      defaultUser = "p";

      mkSystem = system: nixpkgs.lib.nixosSystem {
        inherit system;
        specialArgs = { inherit defaultUser; };
        modules = [ ./wsl.nix ./configuration.nix ];
      };
    in
    {
      nixosConfigurations = {
        aarch64 = mkSystem "aarch64-linux";
        x86_64 = mkSystem "x86_64-linux";
      };
    };
}
