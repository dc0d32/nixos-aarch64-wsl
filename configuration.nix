{ pkgs, defaultUser, ... }:

{
  environment.systemPackages = with pkgs; [
    git
    curl
    wget
    gcc
    gnumake
    pkg-config
    ripgrep
    fd
    htop
    tmux
    unzip
  ];

  programs.zsh.enable = true;
  users.users.${defaultUser}.shell = pkgs.zsh;

  nix.settings = {
    experimental-features = [ "nix-command" "flakes" ];
    trusted-users = [ "root" defaultUser ];
  };

  time.timeZone = "America/Los_Angeles";
  system.stateVersion = "25.11";
}
