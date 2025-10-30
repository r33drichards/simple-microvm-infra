# modules/vm5-restricted-network.nix
# Restricts VM5 to only access GitHub and AWS services
# Uses ipset with iptables for dynamic IP allowlisting

{ config, pkgs, lib, ... }:

let
  # State directory for IP lists
  stateDir = "/var/lib/vm-allowlist";

  # Scripts to fetch and format IP ranges
  fetchGitHubIPs = pkgs.writeShellScript "fetch-github-ips" ''
    set -euo pipefail

    echo "Fetching GitHub IP ranges..."

    # Fetch from official GitHub API
    TEMP_FILE=$(${pkgs.coreutils}/bin/mktemp)

    if ${pkgs.curl}/bin/curl -sf https://api.github.com/meta -o "$TEMP_FILE"; then
      # Extract all IP ranges (git, hooks, web, api, etc.)
      {
        ${pkgs.jq}/bin/jq -r '.git[]?' "$TEMP_FILE"
        ${pkgs.jq}/bin/jq -r '.hooks[]?' "$TEMP_FILE"
        ${pkgs.jq}/bin/jq -r '.web[]?' "$TEMP_FILE"
        ${pkgs.jq}/bin/jq -r '.api[]?' "$TEMP_FILE"
        ${pkgs.jq}/bin/jq -r '.pages[]?' "$TEMP_FILE"
        ${pkgs.jq}/bin/jq -r '.importer[]?' "$TEMP_FILE"
        ${pkgs.jq}/bin/jq -r '.actions[]?' "$TEMP_FILE"
        ${pkgs.jq}/bin/jq -r '.packages[]?' "$TEMP_FILE"
      } | ${pkgs.coreutils}/bin/sort -u > ${stateDir}/github-ips.txt

      ${pkgs.coreutils}/bin/rm "$TEMP_FILE"

      GITHUB_COUNT=$(${pkgs.coreutils}/bin/wc -l < ${stateDir}/github-ips.txt)
      echo "Successfully updated GitHub IPs: $GITHUB_COUNT ranges"
    else
      echo "Failed to fetch GitHub IPs" >&2
      exit 1
    fi
  '';

  fetchAWSIPs = pkgs.writeShellScript "fetch-aws-ips" ''
    set -euo pipefail

    echo "Fetching AWS IP ranges..."

    # Fetch from official AWS source
    TEMP_FILE=$(${pkgs.coreutils}/bin/mktemp)

    if ${pkgs.curl}/bin/curl -sf https://ip-ranges.amazonaws.com/ip-ranges.json -o "$TEMP_FILE"; then
      # Extract all AWS IPv4 prefixes (all services, all regions)
      ${pkgs.jq}/bin/jq -r '.prefixes[].ip_prefix' "$TEMP_FILE" | \
        ${pkgs.coreutils}/bin/sort -u > ${stateDir}/aws-ips.txt

      ${pkgs.coreutils}/bin/rm "$TEMP_FILE"

      AWS_COUNT=$(${pkgs.coreutils}/bin/wc -l < ${stateDir}/aws-ips.txt)
      echo "Successfully updated AWS IPs: $AWS_COUNT ranges"
    else
      echo "Failed to fetch AWS IPs" >&2
      exit 1
    fi
  '';

  # Script to reload ipsets
  reloadIPSets = pkgs.writeShellScript "reload-ipsets" ''
    set -euo pipefail

    echo "Reloading ipsets..."

    # Create ipsets if they don't exist
    ${pkgs.ipset}/bin/ipset create -exist github_allowlist hash:net family inet
    ${pkgs.ipset}/bin/ipset create -exist aws_allowlist hash:net family inet

    # Create temporary sets for atomic swap
    ${pkgs.ipset}/bin/ipset create -exist github_allowlist_tmp hash:net family inet
    ${pkgs.ipset}/bin/ipset create -exist aws_allowlist_tmp hash:net family inet

    # Flush temporary sets
    ${pkgs.ipset}/bin/ipset flush github_allowlist_tmp
    ${pkgs.ipset}/bin/ipset flush aws_allowlist_tmp

    # Load GitHub IPs into temp set
    if [ -f ${stateDir}/github-ips.txt ]; then
      while IFS= read -r ip; do
        ${pkgs.ipset}/bin/ipset add github_allowlist_tmp "$ip" 2>/dev/null || true
      done < ${stateDir}/github-ips.txt
      echo "Loaded GitHub IPs into temporary set"
    fi

    # Load AWS IPs into temp set
    if [ -f ${stateDir}/aws-ips.txt ]; then
      while IFS= read -r ip; do
        ${pkgs.ipset}/bin/ipset add aws_allowlist_tmp "$ip" 2>/dev/null || true
      done < ${stateDir}/aws-ips.txt
      echo "Loaded AWS IPs into temporary set"
    fi

    # Atomic swap
    ${pkgs.ipset}/bin/ipset swap github_allowlist github_allowlist_tmp
    ${pkgs.ipset}/bin/ipset swap aws_allowlist aws_allowlist_tmp

    # Destroy temporary sets
    ${pkgs.ipset}/bin/ipset destroy github_allowlist_tmp
    ${pkgs.ipset}/bin/ipset destroy aws_allowlist_tmp

    echo "ipsets reloaded successfully"
  '';

in
{
  # Ensure ipset package is available
  environment.systemPackages = [ pkgs.ipset ];

  # Create state directory
  systemd.tmpfiles.rules = [
    "d ${stateDir} 0755 root root -"
  ];

  # Service to fetch GitHub IPs
  systemd.services.fetch-github-ips = {
    description = "Fetch GitHub IP ranges for VM5 allowlist";
    serviceConfig = {
      Type = "oneshot";
      ExecStart = fetchGitHubIPs;
      ExecStartPost = reloadIPSets;
      StateDirectory = "vm-allowlist";
    };
    # Ensure network is up
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
  };

  # Service to fetch AWS IPs
  systemd.services.fetch-aws-ips = {
    description = "Fetch AWS IP ranges for VM5 allowlist";
    serviceConfig = {
      Type = "oneshot";
      ExecStart = fetchAWSIPs;
      ExecStartPost = reloadIPSets;
      StateDirectory = "vm-allowlist";
    };
    # Ensure network is up
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
  };

  # Combined service to run both fetchers
  systemd.services.update-vm5-allowlist = {
    description = "Update VM5 IP allowlists (GitHub + AWS)";
    serviceConfig = {
      Type = "oneshot";
    };
    script = ''
      ${fetchGitHubIPs}
      ${fetchAWSIPs}
      ${reloadIPSets}
    '';
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
  };

  # Timer to update both allowlists daily
  systemd.timers.update-vm5-allowlist = {
    description = "Daily update of VM5 IP allowlists";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "daily";
      Persistent = true;
      RandomizedDelaySec = "1h";
    };
  };

  # Run updater on first boot
  systemd.services.update-vm5-allowlist.wantedBy = [ "multi-user.target" ];

  # Add iptables rules for VM5 restriction
  # These rules integrate with existing firewall configuration
  networking.firewall.extraCommands = ''
    # Create ipsets if not already created by the service
    ipset create -exist github_allowlist hash:net family inet
    ipset create -exist aws_allowlist hash:net family inet

    # VM5 restriction rules (insert at the beginning of FORWARD chain)
    # Rule priority: DNS > GitHub > AWS > Block all

    # Allow DNS queries from VM5 (required for name resolution)
    iptables -I FORWARD 1 -i br-vm5 -p udp --dport 53 -j ACCEPT
    iptables -I FORWARD 2 -i br-vm5 -p tcp --dport 53 -j ACCEPT

    # Allow VM5 to reach GitHub IPs
    iptables -I FORWARD 3 -i br-vm5 -m set --match-set github_allowlist dst -j ACCEPT

    # Allow VM5 to reach AWS IPs
    iptables -I FORWARD 4 -i br-vm5 -m set --match-set aws_allowlist dst -j ACCEPT

    # Log and block all other external traffic from VM5
    # (using a high rule number to ensure it runs after allowlist)
    iptables -A FORWARD -i br-vm5 -o enP2p4s0 -m limit --limit 5/min -j LOG --log-prefix "VM5-BLOCKED: "
    iptables -A FORWARD -i br-vm5 -o enP2p4s0 -j DROP
  '';

  # Clean up ipsets on firewall stop
  networking.firewall.extraStopCommands = ''
    ipset destroy github_allowlist 2>/dev/null || true
    ipset destroy aws_allowlist 2>/dev/null || true
  '';
}
