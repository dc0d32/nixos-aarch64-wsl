# nixos-aarch64-wsl

Minimal NixOS WSL2 module and bootstrap tarball builder.

This repo provides **only** the WSL compatibility layer — boot shims,
`/etc/wsl.conf`, FHS symlinks, systemd services, and a tarball builder.
All user-facing configuration (shell, editor, packages, home-manager)
lives in [dc0d32/nixos](https://github.com/dc0d32/nixos).

## Using as a NixOS module

Add this flake as an input and import the module:

```nix
# In your flake.nix inputs:
nixos-wsl.url = "github:dc0d32/nixos-aarch64-wsl";

# In your nixosSystem modules:
nixos-wsl.nixosModules.default
{
  wsl.enable = true;
  wsl.defaultUser = "p";
}
```

## Building a bootstrap tarball

From an existing Linux system with Nix:

```bash
# aarch64 (ARM64 Windows)
sudo nix run .#nixosConfigurations.aarch64.config.system.build.tarballBuilder

# x86_64
sudo nix run .#nixosConfigurations.x86_64.config.system.build.tarballBuilder
```

Produces `nixos.wsl` in the current directory.

## Importing into WSL

```powershell
wsl --import NixOS $env:USERPROFILE\NixOS .\nixos.wsl
wsl -d NixOS
```

## First-boot flow

The bootstrap tarball includes a one-shot systemd service that runs
automatically on the first boot:

1. Clones `https://github.com/dc0d32/nixos.git` into `~/nixos`
2. Runs `sudo nixos-rebuild switch --flake ~/nixos#<hostname>`
3. Creates a marker file so it never runs again

After first boot completes, the system is fully configured by the
dotfiles repo. Subsequent updates use `nixos-rebuild switch` from
`~/nixos`.

## Module options

| Option | Default | Description |
|--------|---------|-------------|
| `wsl.enable` | `false` | Enable WSL2 compatibility |
| `wsl.defaultUser` | `"nixos"` | Default WSL user name |
| `wsl.firstBoot.enable` | `false` | Enable first-boot provisioning |
| `wsl.firstBoot.repo` | `https://github.com/dc0d32/nixos.git` | Dotfiles repo URL |
| `wsl.firstBoot.clonePath` | `~/nixos` | Clone destination |
| `wsl.firstBoot.flake` | `<clonePath>` | Flake URL/path to build |
| `wsl.firstBoot.host` | `networking.hostName` | `nixosConfigurations.<host>` to build |
