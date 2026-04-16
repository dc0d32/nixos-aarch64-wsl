# nixos-aarch64-wsl

Minimal NixOS WSL2 image, no external dependencies beyond nixpkgs + home-manager.

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

## After import

```
git clone <this-repo> ~/nix
cd ~/nix
sudo nixos-rebuild switch --flake .#aarch64
```

Or use the alias: `nr` (rebuilds from `~/nix`).

## What's included

**System:** git, curl, wget, gcc, gnumake, pkg-config, ripgrep, fd, htop, unzip

**User (via home-manager):** zsh + starship, neovim (treesitter, telescope, lsp, completion), git, direnv
