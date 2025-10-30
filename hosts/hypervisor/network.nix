# hosts/hypervisor/network.nix
# Networking for hypervisor: bridges, NAT, isolation firewall
{ config, pkgs, lib, ... }:
{
  # Create 5 isolated bridges (no physical interfaces attached)
  networking.bridges = {
    "br-vm1" = { interfaces = []; };
    "br-vm2" = { interfaces = []; };
    "br-vm3" = { interfaces = []; };
    "br-vm4" = { interfaces = []; };
    "br-vm5" = { interfaces = []; };
  };

  # Assign gateway IPs to bridges (host side)
  networking.interfaces = {
    br-vm1.ipv4.addresses = [{
      address = "10.1.0.1";
      prefixLength = 24;
    }];
    br-vm2.ipv4.addresses = [{
      address = "10.2.0.1";
      prefixLength = 24;
    }];
    br-vm3.ipv4.addresses = [{
      address = "10.3.0.1";
      prefixLength = 24;
    }];
    br-vm4.ipv4.addresses = [{
      address = "10.4.0.1";
      prefixLength = 24;
    }];
    br-vm5.ipv4.addresses = [{
      address = "10.5.0.1";
      prefixLength = 24;
    }];
  };

  # Enable IP forwarding (required for NAT)
  boot.kernel.sysctl = {
    "net.ipv4.ip_forward" = 1;
  };

  # NAT: allow VMs to access internet through host
  networking.nat = {
    enable = true;

    # IMPORTANT: Change this to your actual physical interface!
    # Find with: ip link show
    # Common names: eth0, ens3, enp0s3, wlan0
    # AWS a1.metal uses: enP2p4s0
    externalInterface = "enP2p4s0";

    # VM bridges that should be NAT'd
    internalInterfaces = [ "br-vm1" "br-vm2" "br-vm3" "br-vm4" "br-vm5" ];
  };

  # Firewall configuration
  networking.firewall = {
    enable = true;

    # Allow Tailscale traffic
    trustedInterfaces = [ "tailscale0" ];

    # Allow SSH from anywhere
    allowedTCPPorts = [ 22 ];

    # Block inter-VM traffic (maintain isolation)
    # Each VM can reach internet but not other VMs
    extraCommands = ''
      # VM1 cannot reach VM2, VM3, VM4, VM5
      iptables -I FORWARD -i br-vm1 -o br-vm2 -j DROP
      iptables -I FORWARD -i br-vm1 -o br-vm3 -j DROP
      iptables -I FORWARD -i br-vm1 -o br-vm4 -j DROP
      iptables -I FORWARD -i br-vm1 -o br-vm5 -j DROP

      # VM2 cannot reach VM1, VM3, VM4, VM5
      iptables -I FORWARD -i br-vm2 -o br-vm1 -j DROP
      iptables -I FORWARD -i br-vm2 -o br-vm3 -j DROP
      iptables -I FORWARD -i br-vm2 -o br-vm4 -j DROP
      iptables -I FORWARD -i br-vm2 -o br-vm5 -j DROP

      # VM3 cannot reach VM1, VM2, VM4, VM5
      iptables -I FORWARD -i br-vm3 -o br-vm1 -j DROP
      iptables -I FORWARD -i br-vm3 -o br-vm2 -j DROP
      iptables -I FORWARD -i br-vm3 -o br-vm4 -j DROP
      iptables -I FORWARD -i br-vm3 -o br-vm5 -j DROP

      # VM4 cannot reach VM1, VM2, VM3, VM5
      iptables -I FORWARD -i br-vm4 -o br-vm1 -j DROP
      iptables -I FORWARD -i br-vm4 -o br-vm2 -j DROP
      iptables -I FORWARD -i br-vm4 -o br-vm3 -j DROP
      iptables -I FORWARD -i br-vm4 -o br-vm5 -j DROP

      # VM5 cannot reach VM1, VM2, VM3, VM4
      iptables -I FORWARD -i br-vm5 -o br-vm1 -j DROP
      iptables -I FORWARD -i br-vm5 -o br-vm2 -j DROP
      iptables -I FORWARD -i br-vm5 -o br-vm3 -j DROP
      iptables -I FORWARD -i br-vm5 -o br-vm4 -j DROP
    '';
  };
}
