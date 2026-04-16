# Minimal WSL2 compatibility module
# Handles boot, wsl.conf, /bin, systemd init shim, and tarball building.
{ config, lib, pkgs, defaultUser, ... }:

let
  # Init shim — WSL2 calls /sbin/init to start systemd.
  # NixOS has systemd in /nix/store, so we bridge the gap.
  initShim = pkgs.writeShellScript "wsl-init" ''
    export PATH="${lib.makeBinPath [ pkgs.coreutils pkgs.util-linux ]}:$PATH"

    # Fix /dev/shm if WSL created it as a symlink
    if [ -L /dev/shm ]; then
      rm -f /dev/shm
      mkdir -p /dev/shm
      mount --move /run/shm /dev/shm
      mount --bind /dev/shm /run/shm
    fi

    # Systemd needs shared mount propagation
    mount --make-rshared /

    # Protect nix store — read-only bind mount
    mount --bind /nix/store /nix/store
    mount -o remount,ro,bind /nix/store

    # Create /run/current-system so systemd finds its units.
    # Full activation runs later via nixos-activation.service.
    ln -sfn /nix/var/nix/profiles/system /run/current-system

    # Hand off to real systemd
    exec /nix/var/nix/profiles/system/systemd/lib/systemd/systemd "$@"
  '';
in
{
  # WSL provides its own kernel and boot
  boot = {
    bootspec.enable = false;
    initrd.enable = false;
    kernel.enable = false;
    loader.grub.enable = false;
    modprobeConfig.enable = false;
  };
  system.build.installBootLoader = "${pkgs.coreutils}/bin/true";
  console.enable = false;

  # Networking — WSL handles DHCP, DNS, and /etc/hosts
  networking.dhcpcd.enable = false;
  networking.firewall.enable = false;
  environment.etc.hosts.enable = false;
  environment.etc."resolv.conf".enable = false;

  # /etc/wsl.conf
  environment.etc."wsl.conf".text = lib.generators.toINI {} {
    automount = {
      enabled = true;
      root = "/mnt";
      options = "metadata,uid=1000,gid=100";
    };
    boot.systemd = true;
    interop = {
      enabled = true;
      appendWindowsPath = true;
    };
    network = {
      generateHosts = true;
      generateResolvConf = true;
    };
    user.default = defaultUser;
  };

  # Populate /bin and /sbin — WSL expects these at standard paths
  system.activationScripts.populateBin = lib.stringAfter [] ''
    echo "setting up /bin..."
    mkdir -p /bin
    ln -sf /init /bin/wslpath
    ln -sf ${pkgs.bashInteractive}/bin/bash /bin/bash
    ln -sf ${pkgs.bashInteractive}/bin/bash /bin/sh
    ln -sf ${pkgs.util-linux}/bin/mount /bin/mount
    ln -sf ${pkgs.shadow}/bin/login /bin/login
  '';

  system.activationScripts.shimSystemd = lib.stringAfter [ "populateBin" ] ''
    echo "setting up /sbin/init shim..."
    mkdir -p /sbin
    ln -sf ${initShim} /sbin/init
  '';

  # User
  users.users.${defaultUser} = {
    isNormalUser = true;
    uid = lib.mkDefault 1000;
    extraGroups = [ "wheel" ];
    linger = true;
  };
  users.users.root.extraGroups = [ "root" ];
  security.sudo.wheelNeedsPassword = lib.mkDefault false;

  # Preserve Windows PATH
  environment.variables.PATH = [ "$PATH" ];

  # Systemd — disable units that don't work or aren't needed in WSL
  services.timesyncd.enable = false;
  services.udev.enable = lib.mkDefault false;
  systemd.oomd.enable = lib.mkDefault false;
  systemd.enableEmergencyMode = false;
  powerManagement.enable = false;

  # Tarball builder — produces a .wsl file for `wsl --import`
  system.build.tarballBuilder = pkgs.writeShellApplication {
    name = "nixos-wsl-tarball-builder";
    runtimeInputs = with pkgs; [ coreutils gnutar nixos-install-tools pigz config.nix.package ];
    text = ''
      if [ "$EUID" -ne 0 ]; then
        echo "Must be run as root" >&2
        exit 1
      fi

      out="''${1:-nixos.wsl}"
      root=$(mktemp -d -p "''${TMPDIR:-/tmp}" nixos-wsl.XXXXXXXXXX)
      chmod o+rx "$root"
      trap 'rm -rf "$root" 2>/dev/null || true' EXIT

      echo "Installing NixOS..."
      nixos-install --root "$root" --no-root-passwd \
        --system ${config.system.build.toplevel} --substituters ""

      echo "Compressing..."
      tar -C "$root" -c --sort=name --mtime='@1' --numeric-owner --hard-dereference . \
        | pigz > "$out"

      echo "Done: $out"
    '';
  };
}
