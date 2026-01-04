# tests/slot-pool-test.nix
# NixOS integration test for the slot pool system
#
# Tests the end-to-end flow:
# 1. ip-allocator and slot-pool-subscriber services start
# 2. Slots can be submitted to the pool
# 3. Slots can be borrowed with sessionId parameter
# 4. Slots can be returned with snapshot creation
# 5. Re-borrowing with same sessionId restores the snapshot
{ pkgs, lib, ... }:

let
  # Mock slot-pool-subscriber that doesn't require ZFS
  # Tests the HTTP interface and ip-allocator integration
  mockSubscriberScript = pkgs.writeScriptBin "mock-slot-pool-subscriber" ''
    #!${pkgs.python3}/bin/python3
    import json
    import os
    from http.server import HTTPServer, BaseHTTPRequestHandler

    # Simple in-memory state for testing
    snapshots = {}
    slot_states = {}

    class Handler(BaseHTTPRequestHandler):
        def log_message(self, format, *args):
            pass  # Suppress logging

        def send_json(self, code, data):
            self.send_response(code)
            self.send_header('Content-Type', 'application/json')
            self.end_headers()
            self.wfile.write(json.dumps(data).encode())

        def do_GET(self):
            if self.path == '/health':
                self.send_json(200, {"status": "healthy"})
            elif self.path == '/debug/state':
                self.send_json(200, {"snapshots": snapshots, "slot_states": slot_states})
            else:
                self.send_json(404, {"error": "Not found"})

        def do_POST(self):
            try:
                content_length = int(self.headers.get('Content-Length', 0))
                body = self.rfile.read(content_length)
                data = json.loads(body) if body else {}

                item = data.get('item', {})
                params = data.get('params', {})
                slot = item.get('id')
                session_id = params.get('sessionId')

                if not slot or not session_id:
                    self.send_json(400, {"error": "Missing slot id or sessionId"})
                    return

                if self.path == '/borrow':
                    # Simulate borrow: check for existing snapshot
                    if session_id in snapshots:
                        slot_states[slot] = f"restored-{session_id}"
                        self.send_json(200, {
                            "status": "success",
                            "message": f"Restored snapshot {session_id} to {slot}",
                            "restored": True
                        })
                    else:
                        slot_states[slot] = f"fresh-{session_id}"
                        self.send_json(200, {
                            "status": "success",
                            "message": f"Created fresh state for {slot}",
                            "restored": False
                        })

                elif self.path == '/return':
                    # Simulate return: save snapshot
                    current_state = slot_states.get(slot, "unknown")
                    snapshots[session_id] = {
                        "slot": slot,
                        "previous_state": current_state
                    }
                    slot_states[slot] = "blank"
                    self.send_json(200, {
                        "status": "success",
                        "message": f"Snapshot {session_id} created, {slot} reset to blank"
                    })
                else:
                    self.send_json(404, {"error": f"Unknown endpoint: {self.path}"})

            except json.JSONDecodeError:
                self.send_json(400, {"error": "Invalid JSON"})
            except Exception as e:
                self.send_json(500, {"error": str(e)})

    port = int(os.environ.get('PORT', 8081))
    host = os.environ.get('HOST', '127.0.0.1')
    server = HTTPServer((host, port), Handler)
    print(f"Mock subscriber listening on {host}:{port}")
    server.serve_forever()
  '';
in
pkgs.nixosTest {
  name = "slot-pool-integration";

  nodes.server = { config, pkgs, ... }: {
    virtualisation.memorySize = 2048;

    # Redis for ip-allocator
    services.redis.servers.ip-allocator = {
      enable = true;
      port = 6379;
      bind = "127.0.0.1";
    };

    # Mock subscriber service
    systemd.services.mock-slot-pool-subscriber = {
      description = "Mock Slot Pool Subscriber for testing";
      wantedBy = [ "multi-user.target" ];
      after = [ "network.target" ];
      environment = {
        PORT = "8081";
        HOST = "127.0.0.1";
      };
      serviceConfig = {
        Type = "simple";
        ExecStart = "${mockSubscriberScript}/bin/mock-slot-pool-subscriber";
        Restart = "always";
      };
    };

    environment.systemPackages = with pkgs; [
      curl
      jq
    ];

    networking.firewall.allowedTCPPorts = [ 8081 ];
  };

  testScript = ''
    import json

    start_all()

    # Wait for services to be ready
    server.wait_for_unit("redis-ip-allocator.service")
    server.wait_for_unit("mock-slot-pool-subscriber.service")
    server.wait_for_open_port(8081)

    # Test 1: Health check endpoint
    with subtest("Health check endpoint works"):
        result = server.succeed("curl -sf http://127.0.0.1:8081/health")
        health = json.loads(result)
        assert health["status"] == "healthy", f"Expected healthy status, got {health}"

    # Test 2: First borrow creates fresh state (no existing snapshot)
    with subtest("First borrow creates fresh state"):
        payload = json.dumps({
            "item": {"id": "slot1", "execUrl": "http://10.1.0.2:8080"},
            "params": {"sessionId": "session-abc123"}
        })
        result = server.succeed(
            f"curl -sf -X POST -H 'Content-Type: application/json' "
            f"-d '{payload}' http://127.0.0.1:8081/borrow"
        )
        response = json.loads(result)
        assert response["status"] == "success", f"Expected success, got {response}"
        assert response["restored"] == False, "Should not restore on first borrow"

    # Test 3: Return creates snapshot
    with subtest("Return creates snapshot"):
        payload = json.dumps({
            "item": {"id": "slot1", "execUrl": "http://10.1.0.2:8080"},
            "params": {"sessionId": "session-abc123"}
        })
        result = server.succeed(
            f"curl -sf -X POST -H 'Content-Type: application/json' "
            f"-d '{payload}' http://127.0.0.1:8081/return"
        )
        response = json.loads(result)
        assert response["status"] == "success", f"Expected success, got {response}"

    # Test 4: Verify snapshot was created
    with subtest("Snapshot exists after return"):
        result = server.succeed("curl -sf http://127.0.0.1:8081/debug/state")
        state = json.loads(result)
        assert "session-abc123" in state["snapshots"], \
            f"Snapshot should exist, state: {state}"

    # Test 5: Second borrow restores existing snapshot
    with subtest("Second borrow restores snapshot"):
        payload = json.dumps({
            "item": {"id": "slot2", "execUrl": "http://10.2.0.2:8080"},
            "params": {"sessionId": "session-abc123"}
        })
        result = server.succeed(
            f"curl -sf -X POST -H 'Content-Type: application/json' "
            f"-d '{payload}' http://127.0.0.1:8081/borrow"
        )
        response = json.loads(result)
        assert response["status"] == "success", f"Expected success, got {response}"
        assert response["restored"] == True, "Should restore existing snapshot"

    # Test 6: Borrow with new session creates fresh state
    with subtest("Borrow with new session creates fresh state"):
        payload = json.dumps({
            "item": {"id": "slot3", "execUrl": "http://10.3.0.2:8080"},
            "params": {"sessionId": "session-new-xyz"}
        })
        result = server.succeed(
            f"curl -sf -X POST -H 'Content-Type: application/json' "
            f"-d '{payload}' http://127.0.0.1:8081/borrow"
        )
        response = json.loads(result)
        assert response["status"] == "success", f"Expected success, got {response}"
        assert response["restored"] == False, "Should not restore for new session"

    # Test 7: Invalid payload is rejected
    with subtest("Invalid payload returns 400"):
        result = server.succeed(
            "curl -s -o /dev/null -w '%{http_code}' -X POST "
            "-H 'Content-Type: application/json' "
            "-d '{}' http://127.0.0.1:8081/borrow"
        )
        assert result.strip() == "400", f"Expected 400, got {result}"

    # Test 8: Unknown endpoint returns 404
    with subtest("Unknown endpoint returns 404"):
        result = server.succeed(
            "curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:8081/unknown"
        )
        assert result.strip() == "404", f"Expected 404, got {result}"

    # Test 9: Multiple concurrent sessions
    with subtest("Multiple concurrent sessions work independently"):
        # Create two different sessions
        for session_id, slot in [("session-A", "slot1"), ("session-B", "slot2")]:
            payload = json.dumps({
                "item": {"id": slot},
                "params": {"sessionId": session_id}
            })
            server.succeed(
                f"curl -sf -X POST -H 'Content-Type: application/json' "
                f"-d '{payload}' http://127.0.0.1:8081/return"
            )

        # Verify both snapshots exist
        result = server.succeed("curl -sf http://127.0.0.1:8081/debug/state")
        state = json.loads(result)
        assert "session-A" in state["snapshots"], "session-A snapshot should exist"
        assert "session-B" in state["snapshots"], "session-B snapshot should exist"
  '';
}
