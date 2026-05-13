{
  description = "NixOS WSL2 module + bootstrap tarball builder";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs = { self, nixpkgs }:
    let
      defaultUser = "p";

      # Minimal system for tarball building only — just enough to boot
      # WSL and run the first-boot provisioning service.
      mkBootstrapSystem = { system, hostName }: nixpkgs.lib.nixosSystem {
        inherit system;
        modules = [
          self.nixosModules.default
          ./bootstrap.nix
          ./first-boot.nix
          {
            wsl.enable = true;
            wsl.defaultUser = defaultUser;
            wsl.firstBoot.enable = true;
            networking.hostName = hostName;
            nix.settings.trusted-users = [ "root" defaultUser ];
          }
        ];
      };
    in
    {
      # Reusable NixOS module — import this from your own flake
      nixosModules.default = ./wsl.nix;

      # Bootstrap configurations — used to build the initial .wsl tarball
      nixosConfigurations = {
        aarch64 = mkBootstrapSystem { system = "aarch64-linux"; hostName = "wsl-arm"; };
        x86_64 = mkBootstrapSystem { system = "x86_64-linux"; hostName = "wsl"; };
      };
    };
}
