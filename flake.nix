{
  description = "Minimal NixOS WSL2 image";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    home-manager = {
      url = "github:nix-community/home-manager";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, home-manager }:
    let
      defaultUser = "p";

      mkSystem = system: nixpkgs.lib.nixosSystem {
        inherit system;
        specialArgs = { inherit defaultUser; };
        modules = [
          ./wsl.nix
          ./configuration.nix
          home-manager.nixosModules.home-manager
          {
            home-manager.useGlobalPkgs = true;
            home-manager.useUserPackages = true;
            home-manager.users.${defaultUser} = import ./home.nix;
          }
        ];
      };
    in
    {
      nixosConfigurations = {
        aarch64 = mkSystem "aarch64-linux";
        x86_64 = mkSystem "x86_64-linux";
      };
    };
}
