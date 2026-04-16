# Minimal WSL2 compatibility module
# Handles boot, wsl.conf, /bin, systemd init shim, and tarball building.
{ config, lib, pkgs, defaultUser, ... }:

let
  # Dummy ldconfig — WSL runs /sbin/ldconfig after adding GPU libs.
  # NixOS doesn't use ldconfig (it uses patchelf), so this is a no-op.
  ldconfigDummy = pkgs.writeShellScript "ldconfig" "exit 0";

  # Static C init shim — WSL calls /sbin/init to start systemd.
  # NixOS has systemd in /nix/store, so we bridge the gap:
  # fix /dev/shm, set up mount propagation, protect nix store,
  # create /run/current-system, then exec systemd.
  initShim = pkgs.pkgsStatic.stdenv.mkDerivation {
    name = "wsl-init";
    dontUnpack = true;
    buildPhase = ''
      cat > wsl-init.c << 'CEOF'
      #define _GNU_SOURCE
      #include <stdio.h>
      #include <unistd.h>
      #include <sys/mount.h>
      #include <sys/stat.h>
      #include <string.h>
      #include <errno.h>

      #define SYSTEM_PROFILE "/nix/var/nix/profiles/system"
      #define SYSTEMD_PATH SYSTEM_PROFILE "/systemd/lib/systemd/systemd"

      static void try_mount(const char *src, const char *tgt,
                            unsigned long flags) {
        if (mount(src, tgt, NULL, flags, NULL) != 0)
          fprintf(stderr, "wsl-init: mount %s: %s\n", tgt, strerror(errno));
      }

      int main(int argc, char **argv) {
        (void)argc;
        struct stat st;
        if (lstat("/dev/shm", &st) == 0 && S_ISLNK(st.st_mode)) {
          unlink("/dev/shm");
          mkdir("/dev/shm", 0777);
          try_mount("/run/shm", "/dev/shm", MS_MOVE);
          try_mount("/dev/shm", "/run/shm", MS_BIND);
        }
        try_mount(NULL, "/", MS_REC | MS_SHARED);
        try_mount("/nix/store", "/nix/store", MS_BIND);
        try_mount("/nix/store", "/nix/store", MS_BIND | MS_REMOUNT | MS_RDONLY);
        unlink("/run/current-system");
        if (symlink(SYSTEM_PROFILE, "/run/current-system") != 0)
          perror("wsl-init: symlink");
        argv[0] = "systemd";
        execv(SYSTEMD_PATH, argv);
        perror("wsl-init: execv");
        return 1;
      }
      CEOF
      $CC -O2 -static -o wsl-init wsl-init.c
    '';
    installPhase = ''
      mkdir -p $out/bin
      cp wsl-init $out/bin/
    '';
  };
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

  system.activationScripts.shimSystemd = lib.stringAfter [ "populateBin" ] ''
    echo "setting up /sbin/init..."
    mkdir -p /sbin /usr/lib/systemd /usr/bin /etc/ld.so.conf.d
    ln -sf ${initShim}/bin/wsl-init /sbin/init
    ln -sf ${pkgs.systemd}/lib/systemd/systemd /usr/lib/systemd/systemd
    ln -sf ${pkgs.systemd}/bin/systemctl /usr/bin/systemctl
    ln -sf ${ldconfigDummy} /sbin/ldconfig
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
