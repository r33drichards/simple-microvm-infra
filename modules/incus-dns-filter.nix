# modules/incus-dns-filter.nix
# Per-container domain filtering for Incus using CoreDNS
# Provides programmatic DNS policy management on a per-container basis
{ config, pkgs, lib, ... }:

let
  cfg = config.services.incusDnsFilter;

  # Directory for storing per-container policies
  policyDir = "/var/lib/incus-dns-policies";

  # Upstream DNS servers
  upstreamDNS = cfg.upstreamDNS;

  # Generate CoreDNS Corefile from policy files
  # This script is called by systemd when policies change
  generateCorefileScript = pkgs.writeShellScript "generate-incus-corefile" ''
    set -euo pipefail

    POLICY_DIR="${policyDir}"
    COREFILE="/run/incus-coredns/Corefile"
    UPSTREAM_DNS="${lib.concatStringsSep " " upstreamDNS}"
    DEFAULT_POLICY="${cfg.defaultPolicy}"

    mkdir -p "$(dirname "$COREFILE")"

    # Start building the Corefile
    cat > "$COREFILE.tmp" << 'HEADER'
    # Auto-generated CoreDNS config for Incus container DNS filtering
    # DO NOT EDIT - managed by incus-dns-filter
    # Regenerated on policy changes

    HEADER

    # Process each container policy file
    if [ -d "$POLICY_DIR" ]; then
      for policy_file in "$POLICY_DIR"/*.json 2>/dev/null || true; do
        [ -f "$policy_file" ] || continue

        container_name=$(basename "$policy_file" .json)
        container_ip=$(${pkgs.jq}/bin/jq -r '.ip // empty' "$policy_file")

        [ -z "$container_ip" ] && continue

        # Get allowed domains for this container
        domains=$(${pkgs.jq}/bin/jq -r '.domains[]? // empty' "$policy_file")
        policy_type=$(${pkgs.jq}/bin/jq -r '.policy // "allowlist"' "$policy_file")

        if [ "$policy_type" = "allowlist" ]; then
          # Allowlist mode: only specified domains are allowed
          for domain in $domains; do
            cat >> "$COREFILE.tmp" << EOF
    # Container: $container_name ($container_ip) - Allowed domain
    $domain:5353 {
      bind 127.0.0.1 ${cfg.listenAddress}
      acl {
        allow net $container_ip/32
        block
      }
      forward . $UPSTREAM_DNS
      cache 300
      log
    }

    EOF
          done
        elif [ "$policy_type" = "blocklist" ]; then
          # Blocklist mode: specified domains are blocked, rest allowed
          for domain in $domains; do
            cat >> "$COREFILE.tmp" << EOF
    # Container: $container_name ($container_ip) - Blocked domain
    $domain:5353 {
      bind 127.0.0.1 ${cfg.listenAddress}
      acl {
        allow net $container_ip/32
      }
      template ANY ANY {
        rcode NXDOMAIN
      }
      log . {
        class denial
      }
    }

    EOF
          done
        fi
      done
    fi

    # Default policy for all containers based on global setting
    if [ "$DEFAULT_POLICY" = "allow" ]; then
      # Allow all domains by default
      cat >> "$COREFILE.tmp" << EOF
    # Default: Allow all domains for Incus containers
    .:5353 {
      bind 127.0.0.1 ${cfg.listenAddress}
      forward . $UPSTREAM_DNS
      cache 300
      log
    }
    EOF
    else
      # Deny all domains by default (allowlist mode)
      cat >> "$COREFILE.tmp" << EOF
    # Default: Block all domains not explicitly allowed
    .:5353 {
      bind 127.0.0.1 ${cfg.listenAddress}
      template ANY ANY {
        rcode NXDOMAIN
      }
      log . {
        class denial
      }
    }
    EOF
    fi

    mv "$COREFILE.tmp" "$COREFILE"
    echo "Generated Corefile at $COREFILE"
  '';

  # CLI tool for managing DNS policies
  incusDnsPolicyTool = pkgs.writeShellScriptBin "incus-dns-policy" ''
    set -euo pipefail

    POLICY_DIR="${policyDir}"
    JQ="${pkgs.jq}/bin/jq"

    usage() {
      cat << EOF
    Usage: incus-dns-policy <command> [args...]

    Commands:
      add <container> <domain> [domain...]   Add allowed domains for container
      remove <container> <domain> [domain...] Remove domains from container policy
      set-policy <container> allowlist|blocklist  Set policy type (default: allowlist)
      list [container]                        List policies (all or specific container)
      sync                                    Sync container IPs from Incus
      reload                                  Regenerate CoreDNS config and reload
      delete <container>                      Delete container policy entirely

    Examples:
      incus-dns-policy add mycontainer github.com api.github.com
      incus-dns-policy set-policy mycontainer blocklist
      incus-dns-policy add mycontainer malware.com  # Now blocks this domain
      incus-dns-policy list
      incus-dns-policy sync
      incus-dns-policy reload

    Policy Types:
      allowlist (default): Only specified domains are accessible
      blocklist: Specified domains are blocked, all others allowed
    EOF
      exit 1
    }

    get_container_ip() {
      local container="$1"
      # Get the IPv4 address of the container from Incus
      incus list "$container" --format json 2>/dev/null | \
        $JQ -r '.[0].state.network.eth0.addresses[]? | select(.family == "inet") | .address' 2>/dev/null || echo ""
    }

    ensure_policy_file() {
      local container="$1"
      local policy_file="$POLICY_DIR/$container.json"

      mkdir -p "$POLICY_DIR"

      if [ ! -f "$policy_file" ]; then
        # Get container IP
        local ip=$(get_container_ip "$container")
        if [ -z "$ip" ]; then
          echo "Error: Cannot find IP for container '$container'" >&2
          echo "Make sure the container exists and is running." >&2
          exit 1
        fi

        # Create initial policy file
        echo "{\"container\": \"$container\", \"ip\": \"$ip\", \"policy\": \"allowlist\", \"domains\": []}" > "$policy_file"
      fi
    }

    cmd_add() {
      local container="$1"
      shift
      local domains=("$@")

      if [ ''${#domains[@]} -eq 0 ]; then
        echo "Error: No domains specified" >&2
        exit 1
      fi

      ensure_policy_file "$container"
      local policy_file="$POLICY_DIR/$container.json"

      # Add domains to the policy
      for domain in "''${domains[@]}"; do
        $JQ --arg d "$domain" '.domains += [$d] | .domains |= unique' "$policy_file" > "$policy_file.tmp"
        mv "$policy_file.tmp" "$policy_file"
      done

      echo "Added domains to $container: ''${domains[*]}"
      echo "Run 'incus-dns-policy reload' to apply changes"
    }

    cmd_remove() {
      local container="$1"
      shift
      local domains=("$@")

      local policy_file="$POLICY_DIR/$container.json"

      if [ ! -f "$policy_file" ]; then
        echo "Error: No policy file for container '$container'" >&2
        exit 1
      fi

      # Remove domains from the policy
      for domain in "''${domains[@]}"; do
        $JQ --arg d "$domain" '.domains -= [$d]' "$policy_file" > "$policy_file.tmp"
        mv "$policy_file.tmp" "$policy_file"
      done

      echo "Removed domains from $container: ''${domains[*]}"
      echo "Run 'incus-dns-policy reload' to apply changes"
    }

    cmd_set_policy() {
      local container="$1"
      local policy_type="$2"

      if [[ "$policy_type" != "allowlist" && "$policy_type" != "blocklist" ]]; then
        echo "Error: Policy type must be 'allowlist' or 'blocklist'" >&2
        exit 1
      fi

      ensure_policy_file "$container"
      local policy_file="$POLICY_DIR/$container.json"

      $JQ --arg p "$policy_type" '.policy = $p' "$policy_file" > "$policy_file.tmp"
      mv "$policy_file.tmp" "$policy_file"

      echo "Set policy type for $container: $policy_type"
      echo "Run 'incus-dns-policy reload' to apply changes"
    }

    cmd_list() {
      local container="''${1:-}"

      if [ -n "$container" ]; then
        local policy_file="$POLICY_DIR/$container.json"
        if [ -f "$policy_file" ]; then
          $JQ '.' "$policy_file"
        else
          echo "No policy for container '$container'"
        fi
      else
        echo "=== Incus DNS Policies ==="
        if [ -d "$POLICY_DIR" ]; then
          for policy_file in "$POLICY_DIR"/*.json 2>/dev/null; do
            [ -f "$policy_file" ] || continue
            echo ""
            echo "--- $(basename "$policy_file" .json) ---"
            $JQ '.' "$policy_file"
          done
        else
          echo "No policies configured"
        fi
      fi
    }

    cmd_sync() {
      echo "Syncing container IPs from Incus..."

      mkdir -p "$POLICY_DIR"

      # Get all running containers
      containers=$(incus list --format json | $JQ -r '.[].name')

      for container in $containers; do
        local policy_file="$POLICY_DIR/$container.json"
        local ip=$(get_container_ip "$container")

        if [ -z "$ip" ]; then
          echo "  $container: No IP (skipped)"
          continue
        fi

        if [ -f "$policy_file" ]; then
          # Update IP in existing policy
          $JQ --arg ip "$ip" '.ip = $ip' "$policy_file" > "$policy_file.tmp"
          mv "$policy_file.tmp" "$policy_file"
          echo "  $container: Updated IP to $ip"
        else
          echo "  $container: IP is $ip (no policy file)"
        fi
      done

      echo "Sync complete"
    }

    cmd_reload() {
      echo "Regenerating CoreDNS configuration..."
      ${generateCorefileScript}

      echo "Reloading CoreDNS..."
      systemctl reload incus-coredns 2>/dev/null || systemctl restart incus-coredns

      echo "Done"
    }

    cmd_delete() {
      local container="$1"
      local policy_file="$POLICY_DIR/$container.json"

      if [ -f "$policy_file" ]; then
        rm "$policy_file"
        echo "Deleted policy for $container"
        echo "Run 'incus-dns-policy reload' to apply changes"
      else
        echo "No policy file for container '$container'"
      fi
    }

    # Main command dispatcher
    [ $# -lt 1 ] && usage

    case "$1" in
      add)
        [ $# -lt 3 ] && usage
        cmd_add "''${@:2}"
        ;;
      remove)
        [ $# -lt 3 ] && usage
        cmd_remove "''${@:2}"
        ;;
      set-policy)
        [ $# -ne 3 ] && usage
        cmd_set_policy "$2" "$3"
        ;;
      list)
        cmd_list "''${2:-}"
        ;;
      sync)
        cmd_sync
        ;;
      reload)
        cmd_reload
        ;;
      delete)
        [ $# -ne 2 ] && usage
        cmd_delete "$2"
        ;;
      *)
        usage
        ;;
    esac
  '';

  # Incus hook script to auto-sync policies when containers start
  incusHookScript = pkgs.writeShellScript "incus-dns-hook" ''
    # Called by Incus when container state changes
    # Environment variables: LXD_HOOK_* or INCUS_*

    case "''${INCUS_HOOK_TYPE:-}" in
      start|restart)
        # Sync IPs and reload DNS when containers start
        ${incusDnsPolicyTool}/bin/incus-dns-policy sync
        ${incusDnsPolicyTool}/bin/incus-dns-policy reload
        ;;
    esac
  '';

in {
  options.services.incusDnsFilter = {
    enable = lib.mkEnableOption "Incus per-container DNS filtering";

    listenAddress = lib.mkOption {
      type = lib.types.str;
      default = "10.100.0.1";
      description = "IP address for CoreDNS to listen on (should be Incus bridge gateway)";
    };

    listenPort = lib.mkOption {
      type = lib.types.port;
      default = 5353;
      description = "Port for CoreDNS to listen on";
    };

    upstreamDNS = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ "1.1.1.1" "8.8.8.8" ];
      description = "Upstream DNS servers for allowed domains";
    };

    defaultPolicy = lib.mkOption {
      type = lib.types.enum [ "allow" "deny" ];
      default = "deny";
      description = ''
        Default policy for containers without explicit rules.
        - allow: All domains allowed unless explicitly blocked
        - deny: All domains blocked unless explicitly allowed
      '';
    };

    incusBridge = lib.mkOption {
      type = lib.types.str;
      default = "incusbr0";
      description = "Name of the Incus bridge interface";
    };

    incusNetwork = lib.mkOption {
      type = lib.types.str;
      default = "10.100.0.0/24";
      description = "Incus container network CIDR";
    };
  };

  config = lib.mkIf cfg.enable {
    # Create policy directory
    systemd.tmpfiles.rules = [
      "d ${policyDir} 0755 root root -"
      "d /run/incus-coredns 0755 root root -"
    ];

    # CoreDNS service for Incus containers
    systemd.services.incus-coredns = {
      description = "CoreDNS for Incus container DNS filtering";
      after = [ "network.target" "incus.service" ];
      wantedBy = [ "multi-user.target" ];

      # Generate initial config before starting
      preStart = ''
        ${generateCorefileScript}
      '';

      serviceConfig = {
        Type = "simple";
        ExecStart = "${pkgs.coredns}/bin/coredns -conf /run/incus-coredns/Corefile";
        ExecReload = "${pkgs.coreutils}/bin/kill -SIGUSR1 $MAINPID";
        Restart = "always";
        RestartSec = "5s";

        # Security hardening
        NoNewPrivileges = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        PrivateTmp = true;
        ReadWritePaths = [ "/run/incus-coredns" policyDir ];

        # Allow binding to privileged ports if needed
        AmbientCapabilities = [ "CAP_NET_BIND_SERVICE" ];
      };
    };

    # nftables rules to redirect Incus container DNS to our CoreDNS
    networking.nftables.tables.incus-dns = {
      family = "ip";
      content = ''
        chain prerouting {
          type nat hook prerouting priority dstnat; policy accept;

          # Redirect DNS from Incus containers to our filtered CoreDNS
          iifname "${cfg.incusBridge}" udp dport 53 dnat to ${cfg.listenAddress}:${toString cfg.listenPort}
          iifname "${cfg.incusBridge}" tcp dport 53 dnat to ${cfg.listenAddress}:${toString cfg.listenPort}
        }

        chain postrouting {
          type nat hook postrouting priority srcnat; policy accept;
        }
      '';
    };

    # Block DNS-over-TLS to prevent bypass
    networking.nftables.tables.incus-filter = {
      family = "inet";
      content = ''
        chain forward {
          type filter hook forward priority filter - 5; policy accept;

          # Block DNS-over-TLS from Incus containers to prevent DNS filtering bypass
          iifname "${cfg.incusBridge}" tcp dport 853 drop

          # Block DNS-over-HTTPS common ports (optional, can be expanded)
          # Note: Full DoH blocking requires deep packet inspection
        }
      '';
    };

    # Add CLI tool to system packages
    environment.systemPackages = [
      incusDnsPolicyTool
      pkgs.jq
    ];

    # Timer to periodically sync container IPs
    systemd.timers.incus-dns-sync = {
      description = "Periodic sync of Incus container IPs";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = "2min";
        OnUnitActiveSec = "5min";
        Unit = "incus-dns-sync.service";
      };
    };

    systemd.services.incus-dns-sync = {
      description = "Sync Incus container IPs for DNS filtering";
      after = [ "incus.service" "incus-coredns.service" ];

      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${incusDnsPolicyTool}/bin/incus-dns-policy sync";
        ExecStartPost = "${incusDnsPolicyTool}/bin/incus-dns-policy reload";
      };
    };
  };
}
