# Minimal stage-0 WSL bootstrap tarball — NOT a NixOS system.
#
# Produces a hand-rolled rootfs (~30 MiB uncompressed, ~10-15 MiB
# compressed) containing only:
#   - busybox (static)         provides /bin/{sh,ash,...} + an init shim
#   - nix       (static)       single 31 MiB binary, no runtime closure
#   - first-boot.sh            fetches the real config flake, activates
#                              it, rewires /sbin/init, then prompts the
#                              user to `wsl --shutdown`.
#
# The dotfiles' NixOS configuration is fetched from cache.nixos.org on
# first boot; nothing about it is baked in. After reboot, full systemd
# NixOS takes over and the stage-0 binaries are garbage-collected on
# the next `nix-collect-garbage`.
{
  pkgs,
  lib ? pkgs.lib,
  defaultUser ? "p",
  uid ? 1000,
  flake ? "github:dc0d32/nixos",
  hostName ? "wsl-arm",
}:

let
  inherit (pkgs) runCommand stdenv;

  # Static busybox (musl) — single 1.6 MiB binary with all the standard
  # applets. The default `pkgs.busybox` is dynamically linked against
  # the build glibc, which won't exist in our hand-rolled rootfs.
  busyboxStatic = pkgs.pkgsStatic.busybox;

  # Stripped, statically-linked nix (single-binary).
  nixStaticStripped = runCommand "nix-static-stripped"
    {
      nativeBuildInputs = [ pkgs.binutils ];
      meta.platforms = lib.platforms.linux;
    } ''
      mkdir -p $out/bin
      cp ${pkgs.pkgsStatic.nix}/bin/nix $out/bin/nix
      chmod +w $out/bin/nix
      strip --strip-all $out/bin/nix
      chmod -w $out/bin/nix
      for n in nix-build nix-channel nix-collect-garbage nix-copy-closure \
               nix-daemon nix-env nix-hash nix-instantiate nix-prefetch-url \
               nix-shell nix-store; do
        ln -s nix $out/bin/$n
      done
    '';

  # The first-boot script. Runs once on initial WSL launch via
  # /etc/wsl.conf [boot] command. Must be POSIX sh (busybox ash).
  firstBootScript = pkgs.writeScript "wsl-first-boot.sh" ''
    #!/bin/sh
    set -eu

    MARKER=/var/lib/wsl-first-boot-done
    INPROGRESS=/var/lib/wsl-first-boot-in-progress
    LOG=/var/log/wsl-first-boot.log

    if [ -e "$MARKER" ]; then
      exit 0
    fi

    mkdir -p /var/lib /var/log

    # Two log destinations: file (so it survives) + console (so user
    # sees something even if they peek mid-run).
    : > "$LOG"
    chmod 0644 "$LOG"

    log() { echo "[wsl-first-boot] $*" | tee -a "$LOG" >/dev/console 2>&1 || echo "[wsl-first-boot] $*" >> "$LOG"; }

    fail() {
      log "ERROR: $*"
      log "See $LOG for details."
      log "After fixing, re-run /etc/wsl-first-boot.sh manually."
      rm -f "$INPROGRESS"
      exit 1
    }

    touch "$INPROGRESS"

    # Detailed trace goes only to log; status messages go to console too.
    exec 3>>"$LOG"

    log "=== WSL stage-0 first boot ==="
    date >> "$LOG"

    export PATH=/usr/local/bin:/bin:/sbin
    export HOME=/root
    export USER=root
    export NIX_CONF_DIR=/etc/nix
    export NIX_REMOTE=
    export NIX_SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt
    export TMPDIR=/tmp

    mkdir -p /tmp /var/tmp /run /root \
             /nix/store \
             /nix/var/nix/db \
             /nix/var/nix/gcroots \
             /nix/var/nix/profiles \
             /nix/var/nix/temproots \
             /nix/var/nix/userpool \
             /nix/var/log/nix/drvs \
             /etc/nix

    if [ ! -f /etc/nix/nix.conf ]; then
      cat > /etc/nix/nix.conf <<EOF
    experimental-features = nix-command flakes
    build-users-group =
    sandbox = false
    EOF
    fi

    FLAKE="$${WSL_FLAKE_REF:-${flake}}"
    HOST="$${WSL_HOSTNAME:-${hostName}}"
    ATTR="$FLAKE#nixosConfigurations.$HOST.config.system.build.toplevel"

    log "Building $ATTR..."
    log "(this is a one-shot ~5-15 min download from cache.nixos.org)"

    SYSTEM=$(nix \
      --extra-experimental-features 'nix-command flakes' \
      --log-format raw \
      build --no-link --print-out-paths "$ATTR" 2>>"$LOG") \
      || fail "nix build failed"

    log "Built system: $SYSTEM"

    nix-env --profile /nix/var/nix/profiles/system --set "$SYSTEM" >>"$LOG" 2>&1 \
      || fail "setting system profile failed"

    mkdir -p /run
    ln -sfn /nix/var/nix/profiles/system /run/current-system

    # Wire systemd in for the next boot. WSL execs /sbin/init when
    # boot.systemd is true; the new NixOS system's /init handles
    # NixOS-stage2 + systemd properly.
    mkdir -p /sbin
    ln -sfn "$SYSTEM/init" /sbin/init

    # Replace stage-0 /etc/wsl.conf with the dotfiles' one (enables
    # boot.systemd, sets default user, etc.).
    if [ -f "$SYSTEM/etc/wsl.conf" ]; then
      cp -f "$SYSTEM/etc/wsl.conf" /etc/wsl.conf
      log "Updated /etc/wsl.conf from new system."
    else
      log "WARNING: $SYSTEM has no /etc/wsl.conf — boot.systemd may not be enabled."
    fi

    touch "$MARKER"
    rm -f "$INPROGRESS"

    cat > /etc/motd <<'EOF'

    ===================================================
      Stage-0 bootstrap complete.
      From a Windows shell, run:    wsl --shutdown
      Then re-launch this distro to enter full NixOS.
    ===================================================

    EOF

    log "=== first-boot complete ==="
    cat /etc/motd >/dev/console 2>/dev/null || cat /etc/motd
  '';

  # /etc/passwd: just root. Default user is created by the real NixOS
  # system on first activation.
  passwd = ''
    root:x:0:0::/root:/bin/sh
  '';
  group = ''
    root:x:0:
  '';
  shadow = ''
    root::1::::::
  '';

  nixConf = ''
    experimental-features = nix-command flakes
    build-users-group =
    sandbox = false
  '';

  wslConf = ''
    [automount]
    enabled = true
    options = "metadata,uid=${toString uid},gid=100"
    root = /mnt

    [boot]
    command = /etc/wsl-first-boot.sh
    systemd = false

    [interop]
    appendWindowsPath = true
    enabled = true

    [network]
    generateHosts = true
    generateResolvConf = true

    [user]
    default = root
  '';

  # Common busybox applets we want guaranteed-present at well-known
  # paths even if PATH is empty.
  binSymlinks = [
    "[" "ash" "awk" "bash" "cat" "chgrp" "chmod" "chown" "cp" "cut"
    "date" "dd" "df" "dirname" "echo" "env" "expr" "false" "find"
    "getopt" "grep" "gunzip" "gzip" "head" "hostname" "id" "less" "ln"
    "ls" "mkdir" "mknod" "mktemp" "more" "mount" "mv" "printenv"
    "printf" "ps" "pwd" "readlink" "rm" "rmdir" "sed" "seq" "sh"
    "sleep" "sort" "stat" "su" "sync" "tail" "tar" "tee" "test"
    "touch" "tr" "true" "umount" "uname" "uniq" "unxz" "wc" "wget"
    "which" "xargs" "xz" "xzcat" "yes"
  ];

  sbinSymlinks = [ "halt" "ifconfig" "init" "poweroff" "reboot" "route" "sysctl" ];

in
runCommand "nixos-wsl-bootstrap-min-${pkgs.stdenv.hostPlatform.system}.tar.gz"
  {
    nativeBuildInputs = [ pkgs.gnutar pkgs.gzip ];
    meta = {
      description = "Minimal stage-0 WSL2 bootstrap tarball (busybox + static nix only)";
      platforms = lib.platforms.linux;
    };
  } ''
    set -euo pipefail
    root=$(mktemp -d)
    cd "$root"

    mkdir -p bin sbin etc etc/nix usr/local/bin var var/lib var/log \
             root tmp dev proc sys run mnt home \
             nix nix/store nix/var nix/var/nix nix/var/nix/db \
             nix/var/nix/gcroots nix/var/nix/profiles
    chmod 1777 tmp

    # busybox + applet symlinks
    install -m755 ${busyboxStatic}/bin/busybox bin/busybox
    for app in ${lib.concatStringsSep " " binSymlinks}; do
      ln -sf busybox bin/$app
    done
    for app in ${lib.concatStringsSep " " sbinSymlinks}; do
      ln -sf ../bin/busybox sbin/$app
    done
    # PID 1 — busybox init. After first-boot, /etc/first-boot.sh
    # rewrites this symlink to point at the real systemd from the
    # newly built dotfiles' system.
    ln -sf ../bin/busybox sbin/init

    # nix (static, stripped)
    install -m755 ${nixStaticStripped}/bin/nix usr/local/bin/nix
    for n in nix-build nix-channel nix-collect-garbage nix-copy-closure \
             nix-daemon nix-env nix-hash nix-instantiate nix-prefetch-url \
             nix-shell nix-store; do
      ln -sf nix usr/local/bin/$n
    done

    # /etc files
    cat > etc/passwd <<'EOF'
    ${passwd}EOF
    cat > etc/group <<'EOF'
    ${group}EOF
    cat > etc/shadow <<'EOF'
    ${shadow}EOF
    chmod 0600 etc/shadow

    cat > etc/nix/nix.conf <<'EOF'
    ${nixConf}EOF

    cat > etc/wsl.conf <<'EOF'
    ${wslConf}EOF

    # /etc/profile — runs for any login shell. If first-boot is in
    # progress or hasn't completed, give the user a useful message
    # rather than a bare # prompt.
    cat > etc/profile <<'EOF'
    export PATH=/usr/local/bin:/bin:/sbin
    if [ -e /var/lib/wsl-first-boot-in-progress ]; then
      echo
      echo "  *** WSL stage-0 first-boot is still in progress. ***"
      echo "  Tail the log with:  tail -f /var/log/wsl-first-boot.log"
      echo
    elif [ ! -e /var/lib/wsl-first-boot-done ]; then
      echo
      echo "  *** First-boot has not run yet. To trigger manually: ***"
      echo "      /etc/wsl-first-boot.sh"
      echo
    elif [ -f /etc/motd ]; then
      cat /etc/motd
    fi
    EOF

    # CA bundle (~510 KiB) — required by static nix to talk HTTPS to
    # cache.nixos.org. Static nix probes a list of standard paths;
    # /etc/ssl/certs/ca-certificates.crt is the most portable.
    install -Dm644 ${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt etc/ssl/certs/ca-certificates.crt
    ln -s ca-certificates.crt etc/ssl/certs/ca-bundle.crt

    install -m755 ${firstBootScript} etc/wsl-first-boot.sh

    # Tar it up. Important: --numeric-owner + --sort=name + --mtime
    # for reproducibility; --hard-dereference because WSL's tar
    # extractor doesn't follow hardlinks reliably.
    tar -C "$root" \
        --owner=0 --group=0 \
        --numeric-owner \
        --sort=name \
        --mtime='@1' \
        --hard-dereference \
        -czf "$out" .
  ''
