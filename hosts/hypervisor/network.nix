# hosts/hypervisor/network.nix
# Networking for hypervisor: bridges, NAT, isolation firewall
# Uses networking.nftables.ruleset for atomic updates
{ config, pkgs, lib, ... }:

let
  # Import centralized network definitions
  networks = import ../../modules/networks.nix;

  # Extract list of bridge names for easier iteration
  bridges = lib.attrValues (lib.mapAttrs (_: net: net.bridge) networks.networks);

  # Generate nftables rules to block all inter-VM traffic
  # For each bridge, create rules to DROP traffic to all other bridges
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

  # Generate list of bridge interfaces for nftables sets
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

  # DNS for VMs: dnsmasq listens on bridge IPs (10.X.0.1) and forwards to 1.1.1.1
  services.dnsmasq = {
    enable = true;
    settings = {
      bind-dynamic = true;
      listen-address = lib.mapAttrsToList (_: net: "${net.subnet}.1") networks.networks;
      no-resolv = true;
      server = [ "1.1.1.1" "8.8.8.8" ];
      cache-size = 1000;
    };
  };

  systemd.services.dnsmasq = {
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
  };

  # Enable IP forwarding (required for NAT and VM routing)
  # Enable route_localnet to allow DNAT to 127.0.0.1 (for nginx SNI filter)
  boot.kernel.sysctl = {
    "net.ipv4.ip_forward" = 1;
    "net.ipv4.conf.all.route_localnet" = 1;
  };

  # Disable legacy iptables-based firewall and NAT
  networking.firewall.enable = false;
  networking.nat.enable = false;

  # Use nftables with atomic ruleset updates
  networking.nftables = {
    enable = true;

    # Atomic ruleset - all rules updated together
    # See https://wiki.nftables.org/ for documentation
    ruleset = ''
      # NAT table for internet access and IMDS forwarding
      table ip nat {
        # Prerouting: DNAT for IMDS and DNS redirect
        chain prerouting {
          type nat hook prerouting priority dstnat; policy accept;

          # Forward AWS Instance Metadata Service requests from VMs to hypervisor's IMDS
          # Note: VMs only have a route to IMDS when microvm.allowIMDS = true (default: false)
          # This rule only applies if a VM has the route configured
          ip saddr 10.0.0.0/8 ip daddr 169.254.169.254 tcp dport 80 dnat to 169.254.169.254:80
        }

        # Postrouting: Masquerade for internet and IMDS
        chain postrouting {
          type nat hook postrouting priority srcnat; policy accept;

          # Masquerade IMDS traffic so IMDS sees requests as coming from hypervisor
          # Note: Only applies when VM has microvm.allowIMDS = true (default: false)
          ip saddr 10.0.0.0/8 ip daddr 169.254.169.254 masquerade

          # Masquerade VM traffic to internet via external interface (AWS a1.metal)
          oifname "enP2p4s0" ip saddr 10.0.0.0/8 masquerade
        }
      }

      # Filter table for firewall and isolation
      table inet filter {
        # Input: traffic to hypervisor
        chain input {
          type filter hook input priority filter; policy drop;

          # Accept established/related connections
          ct state { established, related } accept

          # Accept loopback traffic
          iifname "lo" accept

          # Accept Tailscale VPN traffic
          iifname "tailscale0" accept

          # Accept SSH from anywhere
          tcp dport 22 accept

          # Accept HTTP (ACME challenge + redirect) and HTTPS
          tcp dport { 80, 443 } accept

          # Accept traffic from VM bridges (for gateway/DNS services)
          iifname { ${bridgeList} } accept

          # Log and drop everything else
          log prefix "INPUT DROP: " drop
        }

        # Forward: traffic between interfaces (VMs to internet, VM isolation)
        chain forward {
          type filter hook forward priority filter; policy drop;

          # Accept established/related connections
          ct state { established, related } accept

          # Block inter-VM traffic (maintain isolation)
          # Generated dynamically from networks.nix
          ${generateIsolationRules}

          # Accept Tailscale to VM traffic (allow remote access via VPN)
          iifname "tailscale0" oifname { ${bridgeList} } accept

          # === DEFAULT-DENY: VMs cannot reach the internet directly ===
          # Allowed traffic is handled via DNAT to local proxies:
          #   - HTTP  (80)        → nginx HTTP proxy   (127.0.0.1:${toString 3128})
          #   - HTTPS (443)       → nginx SNI filter   (127.0.0.1:${toString 3129})
          #   - SMTP  (25/465/587)→ SES relay proxy    (127.0.0.1:2525)
          #   - DNS               → dnsmasq on gateway (10.X.0.1:53)
          # DNATed traffic becomes INPUT, not FORWARD, so it bypasses this chain.
          # Everything else from VMs is dropped here.

          # Log and drop all other VM-to-internet traffic
          iifname { ${bridgeList} } oifname "enP2p4s0" log prefix "VM OUTBOUND DROP: " drop

          # Log and drop everything else
          log prefix "FORWARD DROP: " drop
        }

        # Output: traffic from hypervisor
        chain output {
          type filter hook output priority filter; policy accept;
        }
      }
    '';
  };
}
