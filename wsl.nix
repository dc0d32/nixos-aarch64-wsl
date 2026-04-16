# Minimal WSL2 compatibility module
# Handles boot, wsl.conf, /bin, systemd, and tarball building.
{ config, lib, pkgs, defaultUser, ... }:

let
  # Dummy ldconfig — WSL runs /sbin/ldconfig after adding GPU libs.
  # NixOS doesn't use ldconfig (it uses patchelf), so this is a no-op.
  ldconfigDummy = pkgs.writeShellScript "ldconfig" "exit 0";
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

  # FHS paths WSL expects — must be in tarball (created during nixos-install)
  system.activationScripts.populateBin = lib.stringAfter [] ''
    echo "setting up /bin..."
    mkdir -p /bin
    ln -sf /init /bin/wslpath
    ln -sf ${pkgs.bashInteractive}/bin/bash /bin/bash
    ln -sf ${pkgs.bashInteractive}/bin/bash /bin/sh
    ln -sf ${pkgs.util-linux}/bin/mount /bin/mount
    ln -sf ${pkgs.shadow}/bin/login /bin/login
  '';

  system.activationScripts.setupFHS = lib.stringAfter [ "populateBin" ] ''
    echo "setting up FHS paths for WSL..."
    mkdir -p /sbin /usr/lib/systemd /usr/bin /etc/ld.so.conf.d
    ln -sf ${pkgs.systemd}/lib/systemd/systemd /sbin/init
    ln -sf ${pkgs.systemd}/lib/systemd/systemd /usr/lib/systemd/systemd
    ln -sf ${pkgs.systemd}/bin/systemctl /usr/bin/systemctl
    ln -sf ${ldconfigDummy} /sbin/ldconfig
  '';

  # Create /run/current-system early via tmpfiles (runs before most units)
  systemd.tmpfiles.rules = [
    "L /run/current-system - - - - /nix/var/nix/profiles/system"
  ];

  # Mount propagation and nix store protection
  systemd.services.wsl-setup = {
    description = "WSL2 NixOS mount setup";
    wantedBy = [ "sysinit.target" ];
    before = [ "sysinit.target" ];
    unitConfig.DefaultDependencies = false;
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = pkgs.writeShellScript "wsl-setup" ''
        if [ -L /dev/shm ]; then
          rm -f /dev/shm
          mkdir -p /dev/shm
          ${pkgs.util-linux}/bin/mount --move /run/shm /dev/shm
          ${pkgs.util-linux}/bin/mount --bind /dev/shm /run/shm
        fi
        ${pkgs.util-linux}/bin/mount --make-rshared /
        ${pkgs.util-linux}/bin/mount --bind /nix/store /nix/store
        ${pkgs.util-linux}/bin/mount -o remount,ro,bind /nix/store
      '';
    };
  };

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

      echo "Copying config to ~/nix..."
      install -d -o 1000 -g 100 "$root/home/${defaultUser}/nix"
      for f in flake.nix flake.lock configuration.nix wsl.nix home.nix README.md .gitignore; do
        [ -e "$f" ] && cp -r "$f" "$root/home/${defaultUser}/nix/"
      done
      chown -R 1000:100 "$root/home/${defaultUser}/nix"

      echo "Compressing..."
      tar -C "$root" -c --sort=name --mtime='@1' --numeric-owner --hard-dereference . \
        | pigz > "$out"

      echo "Done: $out"
    '';
  };
}
