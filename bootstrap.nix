# Bootstrap configuration — used only for the initial WSL tarball.
# After first boot, the dotfiles repo (dc0d32/nixos) takes over via
# nixos-rebuild switch. Keep this minimal.
{ lib, pkgs, ... }:

{
  # Bare minimum to clone the dotfiles repo and rebuild.
  # gitMinimal drops python3 (~130 MiB), perl, and git docs (~70 MiB).
  environment.systemPackages = [
    pkgs.gitMinimal
    pkgs.curl
  ];

  nix.settings = {
    experimental-features = [ "nix-command" "flakes" ];
  };

  # --- Closure-size diet for the bootstrap tarball ---
  # Each option below shaves real megabytes off the .wsl image. The
  # dotfiles repo (dc0d32/nixos) re-enables anything it wants on first
  # rebuild, so this only affects the bootstrap closure.

  # Don't ship the nixpkgs source as a flake registry entry (~190 MiB).
  nix.registry = lib.mkForce { };
  nix.channel.enable = false;

  # Drop NixOS/Nix manuals, groff, texinfo, and per-package -man/-info
  # outputs (~80 MiB total).
  documentation.enable = false;
  documentation.man.enable = false;
  documentation.info.enable = false;
  documentation.nixos.enable = false;

  # Single locale is enough for a bootstrap shell.
  i18n.supportedLocales = [ "en_US.UTF-8/UTF-8" "C.UTF-8/UTF-8" ];

  # Drop installer tools (nixos-install, nixos-enter, nixos-generate-config,
  # nixos-option) from the bootstrap system-path. nixos-rebuild stays —
  # it's brought in by the first-boot service path.
  system.disableInstallerTools = true;

  # Drop perl, rsync, strace from environment.defaultPackages.
  environment.defaultPackages = lib.mkForce [ ];

  # Replace the perl-based NixOS activation scripts with their Rust
  # equivalents. Together these drop perl-5.42 (~57 MiB) and the
  # perl-env wrapper from the closure.
  #   - userborn replaces update-users-groups.pl
  #   - system.etc.overlay replaces setup-etc.pl
  services.userborn.enable = true;
  system.etc.overlay.enable = true;

  # XDG defaults are useless on a headless WSL bootstrap. Together these
  # drop shared-mime-info, glib, hicolor-icon-theme, and
  # sound-theme-freedesktop (~25 MiB).
  xdg.mime.enable = false;
  xdg.icons.enable = false;
  xdg.sounds.enable = false;

  # No fonts needed in a TTY-only bootstrap (drops fontconfig +
  # dejavu-fonts-minimal).
  fonts.fontconfig.enable = false;

  # nano isn't needed on first boot (the dotfiles repo installs an
  # editor); dropping it removes file (~8 MiB).
  programs.nano.enable = false;

  # command-not-found needs an sqlite DB of all of nixpkgs (~5 MiB).
  programs.command-not-found.enable = false;

  # WSL has no kexec or LVM. Drops kexec-tools and lvm2 (~10 MiB).
  boot.kexec.enable = false;
  services.lvm.enable = false;

  system.stateVersion = "25.11";
}
