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

Two flavours, depending on how lean you want the initial download:

### Stage-0 minimal (~14 MiB compressed) — recommended

A hand-rolled non-NixOS rootfs of just `busybox` (static) + `nix`
(static) + a CA bundle + a one-shot first-boot script. On first launch
it fetches and activates the dotfiles' real NixOS system from
`cache.nixos.org`, then prompts you to `wsl --shutdown` so the new
systemd-based system can take over.

```bash
# aarch64
nix build .#packages.aarch64-linux.bootstrap-min
# x86_64
nix build .#packages.x86_64-linux.bootstrap-min
# Result is at ./result — already a .tar.gz, ready for `wsl --import`.
```

Trade-off: ~25× smaller download, but the bootstrap is a one-shot
hand-built rootfs (no NixOS until after first reboot). Override the
flake/host at boot time via `WSL_FLAKE_REF` / `WSL_HOSTNAME` env in
`/etc/wsl-first-boot.sh`.

### Full NixOS bootstrap (~358 MiB compressed)

A complete (if minimal) NixOS-with-systemd image; first-boot is a
systemd service that clones the dotfiles repo over git+HTTPS and runs
`switch-to-configuration switch`.

```bash
# aarch64 (ARM64 Windows)
sudo nix run .#nixosConfigurations.aarch64.config.system.build.tarballBuilder
# x86_64
sudo nix run .#nixosConfigurations.x86_64.config.system.build.tarballBuilder
```

Produces `nixos.wsl` in the current directory.

## Importing into WSL

```powershell
wsl --import NixOS $env:USERPROFILE\NixOS .\result
# (or .\nixos.wsl for the full bootstrap)
wsl -d NixOS
```

## First-boot flow

### Stage-0 minimal

WSL runs `/etc/wsl-first-boot.sh` once via `[boot] command` in
`/etc/wsl.conf`:

1. Initialises a fresh `/nix/store`
2. `nix build github:dc0d32/nixos#nixosConfigurations.<host>.config.system.build.toplevel`
3. Sets the system profile, points `/run/current-system` and
   `/sbin/init` at the new system, copies the new `/etc/wsl.conf`
   (which has `boot.systemd = true`)
4. Touches `/var/lib/wsl-first-boot-done` and prompts the user to
   `wsl --shutdown`
5. After the user re-launches, WSL execs `/sbin/init` → full systemd
   NixOS

If anything goes wrong, the script writes to
`/var/log/wsl-first-boot.log` and leaves a sticky note in
`/etc/profile`; just re-run `/etc/wsl-first-boot.sh` after fixing.

### Full NixOS bootstrap

A two-phase systemd oneshot:

1. `wsl-first-boot-clone.service` (as the default user) clones
   `https://github.com/dc0d32/nixos.git` into `~/nixos`
2. `wsl-first-boot-rebuild.service` (as root) does
   `nix build` + `nix-env --set` + `switch-to-configuration switch`
3. Marker file at `~/.wsl-first-boot-done` prevents re-runs

After first boot, subsequent updates use the dotfiles repo's preferred
workflow (`nixos-rebuild switch` etc.).

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
