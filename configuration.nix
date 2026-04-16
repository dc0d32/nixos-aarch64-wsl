{ pkgs, defaultUser, ... }:

{
  environment.systemPackages = with pkgs; [
    git
    curl
    wget
    neovim
    gcc
    gnumake
    pkg-config
    ripgrep
    fd
    htop
    unzip
  ];

  nix.settings = {
    experimental-features = [ "nix-command" "flakes" ];
    trusted-users = [ "root" defaultUser ];
  };

  time.timeZone = "UTC";
  system.stateVersion = "25.11";
}
