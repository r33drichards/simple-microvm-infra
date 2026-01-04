# tests/slot-pool-test.nix
# NixOS integration test for the slot pool system
#
# Tests the full e2e flow using the actual deployed configuration:
# 1. ip-allocator-webserver receives borrow/return requests
# 2. ip-allocator calls slot-pool-subscriber webhooks
# 3. slot-pool-subscriber manages snapshots (mocked ZFS in test)
# 4. Data flows correctly through the entire system
{ pkgs, lib, ip-allocator, slotPoolSubscriberModule, ... }:

let
  system = pkgs.system;

  # Create mock scripts for ZFS and systemctl that log operations
  # and simulate success for testing the integration
  mockScripts = pkgs.runCommand "mock-scripts" {} ''
    mkdir -p $out/bin

    # Mock ZFS - logs operations and simulates state
    cat > $out/bin/zfs << 'EOF'
#!/bin/sh
echo "MOCK ZFS: $@" >> /tmp/zfs-operations.log

case "$1" in
  list)
    # Return mock snapshot list
    if [ "$2" = "-H" ] && [ "$3" = "-t" ] && [ "$4" = "snapshot" ]; then
      cat /tmp/zfs-snapshots.txt 2>/dev/null || true
    elif [ "$2" = "-H" ]; then
      # Check if dataset exists
      dataset="$3"
      if grep -q "^$dataset$" /tmp/zfs-datasets.txt 2>/dev/null; then
        echo "$dataset"
        exit 0
      else
        exit 1
      fi
    fi
    ;;
  snapshot)
    # Record snapshot creation
    echo "$2" >> /tmp/zfs-snapshots.txt
    ;;
  create)
    # Record dataset creation
    shift
    while [ $# -gt 1 ]; do shift; done
    echo "$1" >> /tmp/zfs-datasets.txt
    ;;
  clone)
    shift
    while [ $# -gt 1 ]; do shift; done
    echo "$1" >> /tmp/zfs-datasets.txt
    ;;
  promote|destroy)
    # Just log, no action needed
    ;;
esac
exit 0
EOF
    chmod +x $out/bin/zfs

    # Mock systemctl - logs operations
    cat > $out/bin/systemctl << 'EOF'
#!/bin/sh
echo "MOCK SYSTEMCTL: $@" >> /tmp/systemctl-operations.log
# Always succeed for start/stop/restart
exit 0
EOF
    chmod +x $out/bin/systemctl

    # Mock chown/chmod for ZFS directory setup
    cat > $out/bin/mock-chown << 'EOF'
#!/bin/sh
exit 0
EOF
    chmod +x $out/bin/mock-chown
  '';

in pkgs.nixosTest {
  name = "slot-pool-integration";

  nodes.server = { config, pkgs, ... }: {
    imports = [
      ip-allocator.nixosModules.default
      slotPoolSubscriberModule
    ];

    virtualisation.memorySize = 2048;

    # Create mock directories and initial state
    systemd.tmpfiles.rules = [
      "d /var/lib/microvms 0755 root root -"
      "d /var/lib/microvms/states 0755 root root -"
      "d /var/lib/microvms/states/slot1 0755 root root -"
      "d /var/lib/microvms/states/slot2 0755 root root -"
      "d /var/lib/microvms/states/slot3 0755 root root -"
      "f /tmp/zfs-snapshots.txt 0644 root root -"
      "f /tmp/zfs-datasets.txt 0644 root root - microvms/storage/states/slot1\nmicrovms/storage/states/slot2\nmicrovms/storage/states/slot3"
      "f /tmp/zfs-operations.log 0644 root root -"
      "f /tmp/systemctl-operations.log 0644 root root -"
      "f /etc/vm-state-assignments.json 0644 root root - {}"
    ];

    # Redis for ip-allocator
    services.redis.servers.ip-allocator = {
      enable = true;
      port = 6379;
      bind = "127.0.0.1";
    };

    # Slot pool subscriber with mock commands in PATH
    services.slotPoolSubscriber = {
      enable = true;
      port = 8081;
      address = "127.0.0.1";
    };

    # Override subscriber service to use mock ZFS/systemctl
    systemd.services.slot-pool-subscriber = {
      path = [ mockScripts pkgs.coreutils ];
      environment = {
        PATH = lib.mkForce "${mockScripts}/bin:${pkgs.coreutils}/bin:${pkgs.util-linux}/bin";
      };
    };

    # IP allocator webserver - same config as production
    services.ip-allocator-webserver = {
      enable = true;
      package = ip-allocator.packages.${system}.default;
      port = 8000;
      address = "0.0.0.0";
      redisUrl = "redis://127.0.0.1:6379";

      # Same subscriber config as production
      subscribers = {
        borrow.subscribers.snapshot-manager = {
          post = "http://127.0.0.1:8081/borrow";
          mustSucceed = true;
          async = false;
        };
        return.subscribers.snapshot-manager = {
          post = "http://127.0.0.1:8081/return";
          mustSucceed = true;
          async = false;
        };
      };
    };

    # Ensure proper service ordering
    systemd.services.ip-allocator-webserver = {
      after = [ "slot-pool-subscriber.service" "redis-ip-allocator.service" ];
      requires = [ "slot-pool-subscriber.service" "redis-ip-allocator.service" ];
    };

    environment.systemPackages = with pkgs; [
      curl
      jq
    ];

    networking.firewall.allowedTCPPorts = [ 8000 8081 ];
  };

  testScript = ''
    import json

    start_all()

    # Wait for all services to be ready
    server.wait_for_unit("redis-ip-allocator.service")
    server.wait_for_unit("slot-pool-subscriber.service")
    server.wait_for_unit("ip-allocator-webserver.service")
    server.wait_for_open_port(6379)
    server.wait_for_open_port(8081)
    server.wait_for_open_port(8000)

    # Test 1: Verify services are running
    with subtest("All services are running"):
        server.succeed("systemctl is-active redis-ip-allocator.service")
        server.succeed("systemctl is-active slot-pool-subscriber.service")
        server.succeed("systemctl is-active ip-allocator-webserver.service")

    # Test 2: Health check on subscriber
    with subtest("Subscriber health check works"):
        result = server.succeed("curl -sf http://127.0.0.1:8081/health")
        health = json.loads(result)
        assert health["status"] == "healthy", f"Expected healthy, got {health}"

    # Test 3: Submit slots to the pool
    with subtest("Submit slots to pool"):
        for slot in ["slot1", "slot2", "slot3"]:
            server.succeed(f"curl -sf -X POST 'http://127.0.0.1:8000/ip/submit?ip={slot}'")

        # Verify pool has 3 free items
        result = server.succeed("curl -sf http://127.0.0.1:8000/admin/stats")
        stats = json.loads(result)
        assert stats["free"] == 3, f"Expected 3 free items, got {stats}"

    # Test 4: Borrow a slot with sessionId (first time - no existing snapshot)
    with subtest("Borrow slot creates fresh state for new session"):
        result = server.succeed(
            "curl -sf -X GET 'http://127.0.0.1:8000/ip/borrow?sessionId=test-session-123'"
        )
        borrow_response = json.loads(result)
        assert "item" in borrow_response, f"Expected item in response, got {borrow_response}"
        assert "token" in borrow_response, f"Expected token in response, got {borrow_response}"

        borrowed_slot = borrow_response["item"]
        borrow_token = borrow_response["token"]

        # Verify pool now has 2 free items
        result = server.succeed("curl -sf http://127.0.0.1:8000/admin/stats")
        stats = json.loads(result)
        assert stats["free"] == 2, f"Expected 2 free items, got {stats}"
        assert stats["borrowed"] == 1, f"Expected 1 borrowed, got {stats}"

    # Test 5: Verify subscriber was called (check ZFS operations log)
    with subtest("Subscriber processed borrow webhook"):
        zfs_log = server.succeed("cat /tmp/zfs-operations.log")
        assert "zfs" in zfs_log.lower() or "MOCK ZFS" in zfs_log, \
            f"Expected ZFS operations, got: {zfs_log}"

    # Test 6: Return the slot (creates snapshot for session)
    with subtest("Return slot creates snapshot"):
        result = server.succeed(
            f"curl -sf -X POST 'http://127.0.0.1:8000/ip/return?token={borrow_token}&sessionId=test-session-123'"
        )

        # Verify pool now has 3 free items again
        result = server.succeed("curl -sf http://127.0.0.1:8000/admin/stats")
        stats = json.loads(result)
        assert stats["free"] == 3, f"Expected 3 free items, got {stats}"
        assert stats["borrowed"] == 0, f"Expected 0 borrowed, got {stats}"

    # Test 7: Verify snapshot was created
    with subtest("Snapshot was created on return"):
        snapshots = server.succeed("cat /tmp/zfs-snapshots.txt")
        assert "test-session-123" in snapshots, \
            f"Expected snapshot for test-session-123, got: {snapshots}"

    # Test 8: Borrow again with same sessionId (should restore snapshot)
    with subtest("Borrow with existing session restores snapshot"):
        result = server.succeed(
            "curl -sf -X GET 'http://127.0.0.1:8000/ip/borrow?sessionId=test-session-123'"
        )
        borrow_response = json.loads(result)
        second_token = borrow_response["token"]

        # Check ZFS log shows clone/restore operation
        zfs_log = server.succeed("cat /tmp/zfs-operations.log")
        # Should see clone operation for restoring snapshot
        assert "clone" in zfs_log.lower() or "MOCK ZFS: clone" in zfs_log, \
            f"Expected clone operation for restore, got: {zfs_log}"

    # Test 9: Verify systemctl was called to restart slots
    with subtest("Systemctl was called to manage slot lifecycle"):
        systemctl_log = server.succeed("cat /tmp/systemctl-operations.log")
        assert "stop" in systemctl_log.lower() or "start" in systemctl_log.lower(), \
            f"Expected start/stop operations, got: {systemctl_log}"

    # Test 10: Return second borrow
    with subtest("Return second borrow succeeds"):
        server.succeed(
            f"curl -sf -X POST 'http://127.0.0.1:8000/ip/return?token={second_token}&sessionId=test-session-123'"
        )

        result = server.succeed("curl -sf http://127.0.0.1:8000/admin/stats")
        stats = json.loads(result)
        assert stats["free"] == 3, f"Expected 3 free items, got {stats}"

    # Test 11: Multiple sessions work independently
    with subtest("Multiple sessions work independently"):
        # Borrow with session A
        result_a = server.succeed(
            "curl -sf -X GET 'http://127.0.0.1:8000/ip/borrow?sessionId=session-A'"
        )
        token_a = json.loads(result_a)["token"]

        # Borrow with session B
        result_b = server.succeed(
            "curl -sf -X GET 'http://127.0.0.1:8000/ip/borrow?sessionId=session-B'"
        )
        token_b = json.loads(result_b)["token"]

        # Return both
        server.succeed(f"curl -sf -X POST 'http://127.0.0.1:8000/ip/return?token={token_a}&sessionId=session-A'")
        server.succeed(f"curl -sf -X POST 'http://127.0.0.1:8000/ip/return?token={token_b}&sessionId=session-B'")

        # Verify both snapshots exist
        snapshots = server.succeed("cat /tmp/zfs-snapshots.txt")
        assert "session-A" in snapshots, "Expected snapshot for session-A"
        assert "session-B" in snapshots, "Expected snapshot for session-B"
  '';
}
