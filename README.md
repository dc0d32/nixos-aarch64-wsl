# nixos-aarch64-wsl

Minimal NixOS WSL2 image, no external dependencies beyond nixpkgs.

## Build

From an existing Linux system with Nix:

```
# aarch64 (ARM64 Windows)
sudo nix run .#nixosConfigurations.aarch64.config.system.build.tarballBuilder

# x86_64
sudo nix run .#nixosConfigurations.x86_64.config.system.build.tarballBuilder
```

Produces `nixos.wsl` in the current directory.

## Import

```powershell
wsl --import NixOS $env:USERPROFILE\NixOS .\nixos.wsl
wsl -d NixOS
```

## Update after import

```
cd /mnt/q/src/nixos-aarch64-wsl
sudo nixos-rebuild switch --flake .#aarch64
```
