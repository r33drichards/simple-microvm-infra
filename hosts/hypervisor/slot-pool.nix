# hosts/hypervisor/slot-pool.nix
# Slot pool configuration - manages VM slots as a borrowable resource pool
#
# Architecture:
# - ip-allocator-webserver: HTTP API for borrowing/returning slots
# - slot-pool-subscriber: Handles webhooks to manage ZFS snapshots
#
# Flow:
# 1. Agent calls POST /ip/borrow with sessionId param
# 2. ip-allocator calls slot-pool-subscriber /borrow webhook
# 3. Subscriber restores session snapshot (or creates fresh state)
# 4. Agent uses the slot
# 5. Agent calls POST /ip/return with borrow token
# 6. ip-allocator calls slot-pool-subscriber /return webhook
# 7. Subscriber snapshots current state and resets slot
{ config, lib, pkgs, ip-allocator, ... }:

{
  # Slot pool subscriber - handles snapshot management webhooks
  services.slotPoolSubscriber = {
    enable = true;
    port = 8081;
    address = "127.0.0.1";  # Only accessible locally
  };

  # IP allocator webserver - manages the slot pool
  services.ip-allocator-webserver = {
    enable = true;
    package = ip-allocator.packages.aarch64-linux.default;
    port = 8000;
    address = "0.0.0.0";  # Accessible from network
    redisUrl = "redis://127.0.0.1:6379";
    openFirewall = true;

    # Configure subscribers for borrow/return events
    subscribers = {
      borrow.subscribers.snapshot-manager = {
        post = "http://127.0.0.1:8081/borrow";
        mustSucceed = true;
        async = false;  # Synchronous - wait for snapshot operations
      };
      return.subscribers.snapshot-manager = {
        post = "http://127.0.0.1:8081/return";
        mustSucceed = true;
        async = false;  # Synchronous - wait for snapshot operations
      };
    };
  };

  # Ensure slot-pool-subscriber starts before ip-allocator
  systemd.services.ip-allocator-webserver = {
    after = [ "slot-pool-subscriber.service" "redis-ip-allocator.service" ];
    requires = [ "slot-pool-subscriber.service" "redis-ip-allocator.service" ];
  };

  # Dedicated Redis instance for ip-allocator (separate from other Redis uses)
  services.redis.servers.ip-allocator = {
    enable = true;
    port = 6379;
    bind = "127.0.0.1";
    settings = {
      maxmemory = "100mb";
      maxmemory-policy = "allkeys-lru";
    };
  };

  # Submit all slots to the pool on first boot
  # This creates the initial pool of borrowable slots
  systemd.services.slot-pool-init = {
    description = "Initialize slot pool with available slots";
    wantedBy = [ "multi-user.target" ];
    after = [ "ip-allocator-webserver.service" "network-online.target" ];
    requires = [ "ip-allocator-webserver.service" ];

    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };

    # Check if slots are already submitted, if not submit them
    script = ''
      set -euo pipefail

      # Wait for ip-allocator to be ready
      for i in $(seq 1 30); do
        if ${pkgs.curl}/bin/curl -sf http://127.0.0.1:8000/admin/stats > /dev/null 2>&1; then
          break
        fi
        sleep 1
      done

      # Get current pool stats
      STATS=$(${pkgs.curl}/bin/curl -sf http://127.0.0.1:8000/admin/stats || echo '{"free":0}')
      FREE=$(echo "$STATS" | ${pkgs.jq}/bin/jq -r '.free // 0')

      # If pool is empty, submit all slots
      if [ "$FREE" -eq 0 ]; then
        echo "Pool is empty, submitting slots..."
        for slot in slot1 slot2 slot3 slot4 slot5; do
          IP="10.''${slot#slot}.0.2"
          echo "Submitting $slot ($IP)..."
          ${pkgs.curl}/bin/curl -sf -X POST "http://127.0.0.1:8000/ip/submit?ip=$slot" || true
        done
        echo "Slots submitted to pool"
      else
        echo "Pool already has $FREE items, skipping initialization"
      fi
    '';
  };
}
