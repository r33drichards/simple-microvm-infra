# modules/home-manager.nix
# Home Manager configuration for desktop VMs
# Based on https://github.com/r33drichards/darwin/blob/main/home.nix
# Provides user environment configuration including zsh, atuin, and git

{ config, pkgs, lib, home-manager, ... }:

{
  imports = [
    home-manager.nixosModules.home-manager
  ];

  home-manager.useGlobalPkgs = true;
  home-manager.useUserPackages = true;

  home-manager.users.robertwendt = { config, pkgs, lib, ... }: {
    # Home Manager needs a bit of information about you and the paths it should
    # manage.
    home.username = "robertwendt";
    home.homeDirectory = "/home/robertwendt";

    # This value determines the Home Manager release that your configuration is
    # compatible with. This helps avoid breakage when a new Home Manager release
    # introduces backwards incompatible changes.
    #
    # You should not change this value, even if you update Home Manager. If you do
    # want to update the value, then make sure to first check the Home Manager
    # release notes.
    home.stateVersion = "23.05"; # Please read the comment before changing.

    # The home.packages option allows you to install Nix packages into your
    # environment.
    home.packages = with pkgs; [
      # Add any additional user-specific packages here
    ];

    # Zsh with oh-my-zsh configuration
    programs.zsh = {
      enable = true;
      enableCompletion = false; # enabled in oh-my-zsh
      initExtra = ''
        export NIXPKGS_ALLOW_UNFREE=1
      '';
      oh-my-zsh = {
        enable = true;
        plugins = [ "git" ];
        theme = "robbyrussell";
      };
    };

    # Enable atuin for better shell history management
    programs.atuin.enable = true;

    # Git credential helper with OAuth support
    programs.git-credential-oauth = {
      enable = true;
    };

    # Session variables
    home.sessionVariables = {
      # Add any session variables here
    };

    # Let Home Manager install and manage itself.
    programs.home-manager.enable = true;
  };

  # Make zsh the default shell for the user
  users.users.robertwendt.shell = pkgs.zsh;

  # Enable zsh system-wide so it can be used as a login shell
  programs.zsh.enable = true;
}
