# hosts/hypervisor/network.nix
# Networking for hypervisor: bridges, NAT, isolation firewall
# All VM network configuration is derived from modules/networks.nix
{ config, pkgs, lib, ... }:

let
  # Import centralized network definitions
  networks = import ../../modules/networks.nix;

  # Extract list of bridge names for easier iteration
  bridges = lib.attrValues (lib.mapAttrs (_: net: net.bridge) networks.networks);

  # Generate firewall rules to block all inter-VM traffic
  # For each bridge, create rules to DROP traffic to all other bridges
  generateIsolationRules =
    let
      # Get list of all bridge names
      allBridges = bridges;
    in
    lib.concatStringsSep "\n" (
      lib.flatten (
        map (sourceBridge:
          let
            # Get all bridges except the source
            targetBridges = lib.filter (b: b != sourceBridge) allBridges;
          in
          # Create DROP rules for this source to all other bridges
          map (targetBridge:
            "      iptables -I FORWARD -i ${sourceBridge} -o ${targetBridge} -j DROP"
          ) targetBridges
        ) allBridges
      )
    );
in
{
  # Create isolated bridges dynamically from networks.nix
  # Each bridge has no physical interfaces attached (pure virtual)
  networking.bridges = lib.mapAttrs (_: _: { interfaces = []; })
    (lib.mapAttrs (_: net: net.bridge) networks.networks);

  # Assign gateway IPs to bridges (host side gets .1 in each subnet)
  networking.interfaces = lib.mapAttrs (_: net: {
    ipv4.addresses = [{
      address = "${net.subnet}.1";
      prefixLength = 24;
    }];
  }) networks.networks;

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

    # VM bridges that should be NAT'd (generated from networks.nix)
    internalInterfaces = bridges;
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
    # Rules are generated dynamically from networks.nix
    extraCommands = ''
${generateIsolationRules}
    '';
  };
}
