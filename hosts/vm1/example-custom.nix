# hosts/vm1/example-custom.nix
# Example of a custom module that can be imported to extend VM functionality
# To use: uncomment the modules line in default.nix and add this file to the list

{ config, pkgs, ... }:

{
  # Example: Add extra packages specific to this VM
  environment.systemPackages = with pkgs; [
    git
    docker
    python3
  ];

  # Example: Configure a service
  # services.postgresql.enable = true;

  # Example: Add custom users
  # users.users.developer = {
  #   isNormalUser = true;
  #   extraGroups = [ "wheel" "docker" ];
  # };

  # Example: Override resource allocation
  # microvm.vcpu = 4;
  # microvm.mem = 8192;
}
