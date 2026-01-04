# modules/incus-vm.nix
# Incus container/VM host - MINIMAL VERSION
# Incus commented out for faster builds
{ config, pkgs, lib, ... }:

{
  # ============================================================
  # MINIMAL CONFIG - SSH only for fast builds
  # ============================================================

  services.openssh.enable = true;
  networking.firewall.allowedTCPPorts = [ 22 ];

  environment.systemPackages = with pkgs; [
    vim
    curl
    htop
    git
  ];

  users.users.robertwendt = {
    isNormalUser = true;
    extraGroups = [ "wheel" ];
    hashedPassword = "$6$9vhPdO0pHckaLgWm$8NPkLKelUAGCjDWTWn7RQ871s4ET3wTpf3zN2vxchyT5MYRkHUbOGXrtwXwMBHReKpLp5syshTLPPn9cid3sI/";
    openssh.authorizedKeys.keys = [
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIHJNEMM9i3WgPeA5dDmU7KMWTCcwLLi4EWfX8CKXuK7s robertwendt@Roberts-Laptop.local"
    ];
  };

  # ============================================================
  # FULL INCUS CONFIG - Uncomment to restore
  # ============================================================

  # virtualisation.incus = {
  #   enable = true;
  #   ui.enable = true;
  #
  #   preseed = {
  #     networks = [
  #       {
  #         name = "incusbr0";
  #         type = "bridge";
  #         config = {
  #           "ipv4.address" = "10.50.0.1/24";
  #           "ipv4.nat" = "true";
  #           "ipv6.address" = "none";
  #         };
  #       }
  #     ];
  #
  #     profiles = [
  #       {
  #         name = "default";
  #         devices = {
  #           eth0 = {
  #             name = "eth0";
  #             network = "incusbr0";
  #             type = "nic";
  #           };
  #           root = {
  #             path = "/";
  #             pool = "default";
  #             type = "disk";
  #           };
  #         };
  #       }
  #     ];
  #
  #     storage_pools = [
  #       {
  #         name = "default";
  #         driver = "dir";
  #         config = {
  #           source = "/var/lib/incus/storage";
  #         };
  #       }
  #     ];
  #
  #     config = {
  #       "core.https_address" = ":8443";
  #     };
  #   };
  # };
  #
  # networking.nftables.enable = true;
  #
  # boot.kernel.sysctl = {
  #   "net.ipv4.ip_forward" = 1;
  #   "net.ipv4.conf.all.forwarding" = 1;
  # };
  #
  # networking.firewall.allowedTCPPorts = [ 22 8443 ];
  # networking.firewall.trustedInterfaces = [ "incusbr0" ];
  #
  # users.users.robertwendt.extraGroups = [ "wheel" "incus-admin" ];
  #
  # systemd.tmpfiles.rules = [
  #   "d /var/lib/incus/storage 0755 root root -"
  # ];
  #
  # environment.systemPackages = with pkgs; [
  #   incus
  # ];
}
