# First-boot provisioning — clones the dotfiles repo and rebuilds.
# Only included in the bootstrap tarball configuration, not in the
# reusable WSL module.
{ config, lib, pkgs, ... }:

let
  cfg = config.wsl.firstBoot;
  user = config.wsl.defaultUser;
  homeDir = "/home/${user}";
  cloneDir = "${homeDir}/nixos";
  markerFile = "${homeDir}/.wsl-first-boot-done";
in
{
  options.wsl.firstBoot = {
    enable = lib.mkEnableOption "first-boot provisioning (clone dotfiles + rebuild)";

    repo = lib.mkOption {
      type = lib.types.str;
      default = "https://github.com/dc0d32/nixos.git";
      description = "Git URL of the dotfiles/NixOS config repo to clone.";
    };

    flake = lib.mkOption {
      type = lib.types.str;
      default = cloneDir;
      description = "Flake path/URL to build the new system from.";
    };

    host = lib.mkOption {
      type = lib.types.str;
      default = config.networking.hostName;
      description = ''
        nixosConfigurations attribute name to build, i.e. the
        'wsl-arm' in '<flake>#nixosConfigurations.wsl-arm'.
      '';
    };

    clonePath = lib.mkOption {
      type = lib.types.str;
      default = cloneDir;
      description = "Where to clone the dotfiles repo.";
    };
  };

  config = lib.mkIf cfg.enable {
    # Two-phase first boot:
    # 1. Clone the dotfiles repo as the default user
    # 2. Build & activate the new system as root using that clone

    systemd.services.wsl-first-boot-clone = {
      description = "Clone dotfiles repo (first boot, phase 1)";
      wantedBy = [ "multi-user.target" ];
      after = [ "network-online.target" "nss-lookup.target" ];
      wants = [ "network-online.target" "nss-lookup.target" ];

      unitConfig.ConditionPathExists = "!${markerFile}";

      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        User = user;
        Group = "users";
        WorkingDirectory = homeDir;
      };

      path = [ pkgs.gitMinimal ];

      script = ''
        set -euo pipefail
        echo "=== WSL first-boot: cloning dotfiles ==="

        if [ -d "${cfg.clonePath}" ]; then
          echo "Clone path ${cfg.clonePath} already exists, skipping."
        else
          echo "Cloning ${cfg.repo} → ${cfg.clonePath}..."
          git clone "${cfg.repo}" "${cfg.clonePath}"
        fi

        echo "=== Clone complete ==="
      '';
    };

    systemd.services.wsl-first-boot-rebuild = {
      description = "Rebuild NixOS from dotfiles (first boot, phase 2)";
      wantedBy = [ "multi-user.target" ];
      after = [ "wsl-first-boot-clone.service" ];
      requires = [ "wsl-first-boot-clone.service" ];

      unitConfig.ConditionPathExists = "!${markerFile}";

      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };

      # Intentionally NOT pulling pkgs.nixos-rebuild here: it's the
      # python-based nixos-rebuild-ng, which would drag python3
      # (~130 MiB) into the bootstrap closure. We do exactly what
      # nixos-rebuild does internally: nix build the toplevel, point
      # the system profile at it, then activate it.
      path = [ pkgs.gitMinimal pkgs.nix pkgs.systemd ];

      script = ''
        set -euo pipefail
        attr="${cfg.flake}#nixosConfigurations.${cfg.host}.config.system.build.toplevel"
        echo "=== WSL first-boot: building $attr ==="
        system="$(nix build --no-link --print-out-paths "$attr")"

        echo "Setting system profile → $system"
        nix-env --profile /nix/var/nix/profiles/system --set "$system"

        echo "Activating new system..."
        "$system/bin/switch-to-configuration" switch

        install -o ${user} -g users -m 644 /dev/null "${markerFile}"
        echo "=== First-boot provisioning complete ==="
      '';
    };
  };
}
