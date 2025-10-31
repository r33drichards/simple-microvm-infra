# hosts/hypervisor/network.nix
# Networking for hypervisor: bridges, NAT, isolation firewall
# Uses NixOS native options with nftables backend
{ config, pkgs, lib, ... }:

let
  # Import centralized network definitions
  networks = import ../../modules/networks.nix;

  # Extract list of bridge names for easier iteration
  bridges = lib.attrValues (lib.mapAttrs (_: net: net.bridge) networks.networks);

  # Generate nftables rules to block all inter-VM traffic
  generateIsolationRules =
    let
      allBridges = bridges;
    in
    lib.concatStringsSep "\n      " (
      lib.flatten (
        map (sourceBridge:
          let
            targetBridges = lib.filter (b: b != sourceBridge) allBridges;
          in
          map (targetBridge:
            "iifname \"${sourceBridge}\" oifname \"${targetBridge}\" drop"
          ) targetBridges
        ) allBridges
      )
    );

  # Generate list of bridge interfaces
  bridgeList = lib.concatStringsSep ", " (map (b: "\"${b}\"") bridges);
in
{
  # Create isolated bridges dynamically from networks.nix
  networking.bridges = lib.mapAttrs' (name: net:
    lib.nameValuePair net.bridge { interfaces = []; }
  ) networks.networks;

  # Assign gateway IPs to bridges
  networking.interfaces = lib.mapAttrs' (name: net:
    lib.nameValuePair net.bridge {
      ipv4.addresses = [{
        address = "${net.subnet}.1";
        prefixLength = 24;
      }];
    }
  ) networks.networks;

  # Enable IP forwarding (required for NAT and VM routing)
  boot.kernel.sysctl = {
    "net.ipv4.ip_forward" = 1;
  };

  # Native NixOS firewall with nftables backend
  networking.firewall = {
    enable = true;

    # Use nftables backend instead of iptables
    backend = "nftables";

    # Allow SSH
    allowedTCPPorts = [ 22 ];

    # Trust Tailscale and bridge interfaces
    trustedInterfaces = [ "tailscale0" ] ++ bridges;

    # Custom rules for inter-VM isolation and logging
    extraForwardRules = ''
      # Block inter-VM traffic (maintain isolation)
      ${generateIsolationRules}

      # Log dropped forward packets for debugging
      log prefix "FORWARD DROP: " drop
    '';

    # Log dropped input packets
    extraInputRules = ''
      log prefix "INPUT DROP: " drop
    '';
  };

  # Native NixOS NAT with nftables
  networking.nat = {
    enable = true;

    # External interface for internet access
    externalInterface = "enP2p4s0";

    # Internal interfaces (VM bridges)
    internalInterfaces = bridges;
  };

  # Additional nftables rules for IMDS forwarding
  # This is the one piece that doesn't have native NixOS options
  networking.nftables.tables = {
    imds-nat = {
      family = "ip";
      content = ''
        # Forward AWS Instance Metadata Service requests from VMs
        chain prerouting {
          type nat hook prerouting priority dstnat + 1;

          # Forward IMDS requests from VMs to hypervisor's IMDS
          # Allows VMs to access EC2 instance role credentials
          ip saddr 10.0.0.0/8 ip daddr 169.254.169.254 tcp dport 80 dnat to 169.254.169.254:80
        }

        chain postrouting {
          type nat hook postrouting priority srcnat + 1;

          # Masquerade IMDS traffic so IMDS sees requests from hypervisor
          ip saddr 10.0.0.0/8 ip daddr 169.254.169.254 masquerade
        }
      '';
    };
  };
}
