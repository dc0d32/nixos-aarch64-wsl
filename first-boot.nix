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

    flakeRef = lib.mkOption {
      type = lib.types.str;
      default = "${cloneDir}#${config.networking.hostName}";
      description = "Flake reference passed to nixos-rebuild switch.";
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
    # 2. Rebuild NixOS as root using that clone

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

      path = [ pkgs.gitMinimal pkgs.openssh ];

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

      path = [ pkgs.gitMinimal pkgs.nix pkgs.nixos-rebuild pkgs.systemd ];

      script = ''
        set -euo pipefail
        echo "=== WSL first-boot: rebuilding NixOS ==="
        echo "Running: nixos-rebuild switch --flake ${cfg.flakeRef}"

        nixos-rebuild switch --flake "${cfg.flakeRef}"

        # Mark first-boot done (owned by the user, not root)
        install -o ${user} -g users -m 644 /dev/null "${markerFile}"

        echo "=== First-boot provisioning complete ==="
      '';
    };
  };
}
