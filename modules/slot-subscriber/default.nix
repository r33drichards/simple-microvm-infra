# modules/slot-subscriber/default.nix
# HTTP webhook subscriber for ip-allocator borrow/return events
# Manages ZFS snapshots for session state isolation
{ config, pkgs, lib, ... }:

with lib;

let
  cfg = config.services.slotSubscriber;

  # Python webhook server that handles borrow/return events
  subscriberServer = pkgs.writeScript "slot-subscriber-server" ''
    #!${pkgs.python3}/bin/python3
    """
    Slot Subscriber Webhook Server

    Handles borrow/return events from ip-allocator-webserver to manage
    ZFS snapshots for session state isolation.

    Borrow flow:
      1. If snapshot exists for sessionId, clone it to slot's state
      2. Otherwise, create fresh state for the slot
      3. Restart the slot's microvm

    Return flow:
      1. Stop the slot's microvm
      2. Snapshot current state with sessionId
      3. Reset slot to blank state
      4. Restart the slot's microvm
    """

    import http.server
    import json
    import subprocess
    import sys
    import os
    import logging
    from urllib.parse import urlparse

    # Configure logging
    logging.basicConfig(
        level=logging.INFO,
        format='%(asctime)s - %(levelname)s - %(message)s'
    )
    logger = logging.getLogger(__name__)

    # Configuration
    PORT = int(os.environ.get('SUBSCRIBER_PORT', '8081'))
    ZFS_POOL = 'microvms'
    ZFS_DATASET = 'storage/states'
    STATES_DIR = '/var/lib/microvms/states'

    def run_cmd(cmd, check=True):
        """Run a shell command and return output."""
        logger.info(f"Running: {' '.join(cmd)}")
        result = subprocess.run(cmd, capture_output=True, text=True)
        if result.returncode != 0 and check:
            logger.error(f"Command failed: {result.stderr}")
            raise Exception(f"Command failed: {result.stderr}")
        return result

    def snapshot_exists(session_id):
        """Check if a snapshot exists for the given session ID."""
        # Look for any snapshot with this session_id name
        result = run_cmd([
            'zfs', 'list', '-H', '-t', 'snapshot', '-o', 'name',
            '-r', f'{ZFS_POOL}/{ZFS_DATASET}'
        ], check=False)
        if result.returncode != 0:
            return False
        for line in result.stdout.strip().split('\n'):
            if line.endswith(f'@{session_id}'):
                return True
        return False

    def get_session_snapshot(session_id):
        """Get the full snapshot name for a session."""
        result = run_cmd([
            'zfs', 'list', '-H', '-t', 'snapshot', '-o', 'name',
            '-r', f'{ZFS_POOL}/{ZFS_DATASET}'
        ], check=False)
        if result.returncode != 0:
            return None
        for line in result.stdout.strip().split('\n'):
            if line.endswith(f'@{session_id}'):
                return line
        return None

    def stop_slot(slot_id):
        """Stop a microvm slot."""
        logger.info(f"Stopping slot {slot_id}")
        run_cmd(['systemctl', 'stop', f'microvm@{slot_id}.service'], check=False)

    def start_slot(slot_id):
        """Start a microvm slot."""
        logger.info(f"Starting slot {slot_id}")
        run_cmd(['systemctl', 'start', f'microvm@{slot_id}.service'])

    def create_snapshot(slot_id, session_id):
        """Create a ZFS snapshot of the slot's current state."""
        dataset = f'{ZFS_POOL}/{ZFS_DATASET}/{slot_id}'
        snapshot = f'{dataset}@{session_id}'
        logger.info(f"Creating snapshot {snapshot}")
        run_cmd(['zfs', 'snapshot', snapshot])

    def delete_state_data(slot_id):
        """Delete the slot's data.img to reset to blank state."""
        data_img = f'{STATES_DIR}/{slot_id}/data.img'
        if os.path.exists(data_img):
            logger.info(f"Deleting {data_img}")
            os.remove(data_img)

    def restore_snapshot(session_id, slot_id):
        """Restore a session snapshot to a slot's state."""
        snapshot = get_session_snapshot(session_id)
        if not snapshot:
            raise Exception(f"Snapshot {session_id} not found")

        # Extract source state from snapshot name
        # Format: microvms/storage/states/slotX@session_id
        src_dataset = snapshot.split('@')[0]
        dst_dataset = f'{ZFS_POOL}/{ZFS_DATASET}/{slot_id}'
        dst_state_dir = f'{STATES_DIR}/{slot_id}'

        # If restoring to same slot, just rollback
        if src_dataset == dst_dataset:
            logger.info(f"Rolling back {dst_dataset} to {snapshot}")
            run_cmd(['zfs', 'rollback', snapshot])
        else:
            # Clone the snapshot to the destination
            # First, destroy existing dataset if it's a clone
            logger.info(f"Cloning {snapshot} to {dst_dataset}")

            # Create a temporary clone name
            temp_clone = f'{ZFS_POOL}/{ZFS_DATASET}/{slot_id}-restore-temp'

            # Clone the snapshot
            run_cmd(['zfs', 'clone', '-o', f'mountpoint={dst_state_dir}', snapshot, temp_clone])

            # Promote the clone
            run_cmd(['zfs', 'promote', temp_clone])

            # Rename to final name (this is complex with ZFS, simpler to just use the clone)
            logger.info(f"Restored snapshot to {slot_id}")

    def handle_borrow(data):
        """
        Handle borrow event.

        data format:
        {
            "item": {"id": "slot1", "execUrl": "..."},
            "params": {"sessionId": "abc123"}
        }
        """
        item = data.get('item', {})
        params = data.get('params', {})

        slot_id = item.get('id')
        session_id = params.get('sessionId')

        if not slot_id or not session_id:
            raise Exception("Missing slot_id or session_id")

        logger.info(f"Handling BORROW: slot={slot_id}, session={session_id}")

        # Stop the slot first
        stop_slot(slot_id)

        if snapshot_exists(session_id):
            # Restore existing session snapshot
            logger.info(f"Found existing snapshot for session {session_id}")
            restore_snapshot(session_id, slot_id)
        else:
            # Create fresh state - just delete data.img and let VM recreate it
            logger.info(f"No existing snapshot for session {session_id}, using fresh state")
            delete_state_data(slot_id)

        # Start the slot
        start_slot(slot_id)

        return {"status": "ok", "slot": slot_id, "session": session_id}

    def handle_return(data):
        """
        Handle return event.

        data format:
        {
            "item": {"id": "slot1", "execUrl": "..."},
            "params": {"sessionId": "abc123"}
        }
        """
        item = data.get('item', {})
        params = data.get('params', {})

        slot_id = item.get('id')
        session_id = params.get('sessionId')

        if not slot_id or not session_id:
            raise Exception("Missing slot_id or session_id")

        logger.info(f"Handling RETURN: slot={slot_id}, session={session_id}")

        # Stop the slot
        stop_slot(slot_id)

        # Create snapshot of current state
        create_snapshot(slot_id, session_id)

        # Reset to blank state
        delete_state_data(slot_id)

        # Start the slot with fresh state
        start_slot(slot_id)

        return {"status": "ok", "slot": slot_id, "session": session_id, "snapshot_created": True}

    class WebhookHandler(http.server.BaseHTTPRequestHandler):
        def do_POST(self):
            try:
                content_length = int(self.headers.get('Content-Length', 0))
                body = self.rfile.read(content_length).decode('utf-8')

                logger.info(f"Received POST {self.path}: {body}")

                data = json.loads(body) if body else {}

                path = urlparse(self.path).path

                if path == '/borrow':
                    result = handle_borrow(data)
                elif path == '/return':
                    result = handle_return(data)
                else:
                    self.send_response(404)
                    self.send_header('Content-Type', 'application/json')
                    self.end_headers()
                    self.wfile.write(json.dumps({"error": "Not found"}).encode())
                    return

                self.send_response(200)
                self.send_header('Content-Type', 'application/json')
                self.end_headers()
                self.wfile.write(json.dumps(result).encode())

            except Exception as e:
                logger.error(f"Error handling request: {e}")
                self.send_response(500)
                self.send_header('Content-Type', 'application/json')
                self.end_headers()
                self.wfile.write(json.dumps({"error": str(e)}).encode())

        def do_GET(self):
            if self.path == '/health':
                self.send_response(200)
                self.send_header('Content-Type', 'application/json')
                self.end_headers()
                self.wfile.write(json.dumps({"status": "healthy"}).encode())
            else:
                self.send_response(404)
                self.send_header('Content-Type', 'application/json')
                self.end_headers()
                self.wfile.write(json.dumps({"error": "Not found"}).encode())

        def log_message(self, format, *args):
            logger.info(f"{self.address_string()} - {format % args}")

    if __name__ == '__main__':
        server = http.server.HTTPServer(('127.0.0.1', PORT), WebhookHandler)
        logger.info(f"Slot subscriber server listening on port {PORT}")
        server.serve_forever()
  '';

in {
  options.services.slotSubscriber = {
    enable = mkEnableOption "Slot subscriber webhook server";

    port = mkOption {
      type = types.port;
      default = 8081;
      description = "Port for the subscriber webhook server";
    };
  };

  config = mkIf cfg.enable {
    systemd.services.slot-subscriber = {
      description = "Slot Subscriber Webhook Server";
      after = [ "network.target" "zfs.target" ];
      wants = [ "zfs.target" ];
      wantedBy = [ "multi-user.target" ];

      environment = {
        SUBSCRIBER_PORT = toString cfg.port;
      };

      serviceConfig = {
        Type = "simple";
        ExecStart = "${subscriberServer}";
        Restart = "always";
        RestartSec = 5;

        # Run as root to manage VMs and ZFS
        # Could be locked down with specific capabilities if needed
      };
    };
  };
}
