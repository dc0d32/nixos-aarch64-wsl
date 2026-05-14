# Minimal WSL2 compatibility module
# Handles boot, wsl.conf, /bin, systemd, and tarball building.
#
# Intended as a reusable NixOS module: consumers import this and set
# `wsl.defaultUser` to wire up a functional NixOS-on-WSL system.
{ config, lib, pkgs, ... }:

let
  cfg = config.wsl;
  defaultUser = cfg.defaultUser;

  # Dummy ldconfig — WSL runs /sbin/ldconfig after adding GPU libs.
  # NixOS doesn't use ldconfig (it uses patchelf), so this is a no-op.
  ldconfigDummy = pkgs.writeShellScript "ldconfig" "exit 0";

  # Wrapped /bin/sh — WSL runs health checks via /bin/sh that call
  # systemctl and grep. NixOS doesn't have these in the default PATH,
  # so we wrap sh to include them.
  shWrapper = pkgs.writeShellScriptBin "sh" ''
    export PATH="${lib.makeBinPath [ pkgs.systemd pkgs.gnugrep pkgs.coreutils ]}:$PATH"
    exec ${pkgs.bashInteractive}/bin/sh "$@"
  '';

  # systemd-shim — runs as /sbin/init. WSL launches /sbin/init in the
  # distro's mount namespace expecting it to be systemd, but systemd
  # cannot start cleanly on a stock WSL rootfs:
  #   * /dev/shm is a symlink to /run/shm (WSL convention). systemd
  #     services with PrivateTmp=yes set up a private /tmp+/dev/shm
  #     bind mount; the symlink confuses that and breaks mount
  #     namespacing.
  #   * / is mounted with private propagation. systemd's hardened
  #     services (ProtectSystem, PrivateTmp, ProtectHome, …) need
  #     to share mount events, which requires / to be rshared first.
  #   * /nix/store is rw — should be ro for safety / matches NixOS
  #     expectations.
  # If any of these are wrong, hardened services hit weird ENOENT/
  # EACCES failures (200/CHDIR cascade) during exec setup, the journal
  # socket may itself fail, and systemd never reaches sd_notify(READY).
  # WSL's WaitForBootProcess then times out after 10s and kills the
  # distro. Fix: do all of the above BEFORE handing control to systemd.
  #
  # Pattern adopted from nix-community/NixOS-WSL (utils/src/shim.rs).
  # Implemented in shell because the operations are simple and we
  # avoid a Rust toolchain dep just for /sbin/init.
  systemdShim = pkgs.writeShellScript "wsl-systemd-shim" ''
    set -e

    log() { echo "[wsl-systemd-shim] $*" > /dev/kmsg 2>/dev/null || true; }

    # 1. Fix /dev/shm if it's still the WSL symlink.
    if [ -L /dev/shm ]; then
      log "unscrewing /dev/shm symlink"
      rm -f /dev/shm
      mkdir -p /dev/shm
      ${pkgs.util-linux}/bin/mount --move /run/shm /dev/shm
      ${pkgs.util-linux}/bin/mount --bind /dev/shm /run/shm
    fi

    # 2. Remount / shared+rec so systemd hardened-service mount
    #    namespacing works.
    log "remounting / shared (rec)"
    ${pkgs.util-linux}/bin/mount --make-rshared /

    # 3. Bind-mount /nix/store read-only.
    log "remounting /nix/store ro"
    ${pkgs.util-linux}/bin/mount --bind /nix/store /nix/store
    ${pkgs.util-linux}/bin/mount -o remount,ro,bind /nix/store

    # 4. Re-run activation (idempotent; matches upstream NixOS-WSL).
    log "running activation"
    /nix/var/nix/profiles/system/activate > /dev/kmsg 2>&1 || \
      log "activation failed (continuing)"

    # 5. Hand off to real systemd with kernel-log target so failures
    #    are visible in dmesg even if journald is unhappy.
    log "exec systemd"
    exec -a "$0" /nix/var/nix/profiles/system/systemd/lib/systemd/systemd \
      --log-target=kmsg "$@"
  '';
in
{
  options.wsl = {
    enable = lib.mkEnableOption "NixOS WSL2 compatibility";

    defaultUser = lib.mkOption {
      type = lib.types.str;
      default = "nixos";
      description = "The default WSL user name.";
    };
  };

  config = lib.mkIf cfg.enable {
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
    networking.resolvconf.enable = false;
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
      ln -sf ${shWrapper}/bin/sh /bin/sh
      ln -sf ${pkgs.util-linux}/bin/mount /bin/mount
      ln -sf ${pkgs.shadow}/bin/login /bin/login
    '';

    system.activationScripts.setupFHS = lib.stringAfter [ "populateBin" ] ''
      echo "setting up FHS paths for WSL..."
      mkdir -p /sbin /usr/lib/systemd /usr/bin /etc/ld.so.conf.d
      # /sbin/init is our shim, NOT systemd directly. See comment on
      # `systemdShim` above for why.
      ln -sf ${systemdShim} /sbin/init
      ln -sf ${pkgs.systemd}/lib/systemd/systemd /usr/lib/systemd/systemd
      ln -sf ${pkgs.systemd}/bin/systemctl /usr/bin/systemctl
      ln -sf ${ldconfigDummy} /sbin/ldconfig
    '';

    # Create /run/current-system early via tmpfiles (runs before most units)
    systemd.tmpfiles.rules = [
      "L /run/current-system - - - - /nix/var/nix/profiles/system"
    ];

    # NOTE: mount propagation, /dev/shm fix, and /nix/store ro
    # bind-mount are handled by the systemd-shim BEFORE systemd
    # starts (see `systemdShim` above). Doing it from a systemd unit
    # is too late: hardened services start their own mount namespaces
    # in parallel with sysinit.target and trip over the bad state
    # before wsl-setup runs.

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
          --system ${config.system.build.toplevel}

        echo "Compressing..."
        tar -C "$root" -c --sort=name --mtime='@1' --numeric-owner --hard-dereference . \
          | pigz > "$out"

        echo "Done: $out"
      '';
    };
  };
}
