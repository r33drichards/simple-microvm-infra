#!/usr/bin/env python3
"""
Slot Pool Subscriber - Handles borrow/return webhooks from ip-allocator-webserver.

Borrow flow:
1. Receive borrow webhook with {item: {id: "slot1", ...}, params: {sessionId: "abc123"}}
2. If snapshot exists for sessionId, restore it to the slot
3. Otherwise, mount blank snapshot and create initial snapshot for session
4. Restart the slot VM

Return flow:
1. Receive return webhook with {item: {id: "slot1", ...}, params: {sessionId: "abc123"}}
2. Snapshot current state with sessionId
3. Mount blank state to the slot
4. Restart the slot VM
"""

import json
import subprocess
import sys
import os
from http.server import HTTPServer, BaseHTTPRequestHandler
import logging

# Import ZFS manager (handles both libzfs_core native and CLI fallback)
from zfs_manager import ZFSManager

# Configure logging
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s [%(levelname)s] %(message)s',
    handlers=[logging.StreamHandler(sys.stdout)]
)
logger = logging.getLogger(__name__)

# Configuration
STATES_DIR = "/var/lib/microvms/states"
ZFS_POOL = "microvms"
ZFS_DATASET = "storage/states"
BLANK_STATE_PREFIX = "blank-"

# Initialize ZFS manager
zfs = ZFSManager(pool=ZFS_POOL, base_dataset=ZFS_DATASET)


def run_command(cmd, check=True):
    """Run a shell command and return output."""
    logger.info(f"Running: {' '.join(cmd)}")
    result = subprocess.run(cmd, capture_output=True, text=True)
    if result.returncode != 0:
        logger.error(f"Command failed: {result.stderr}")
        if check:
            raise subprocess.CalledProcessError(result.returncode, cmd, result.stdout, result.stderr)
    return result


def snapshot_exists(session_id):
    """Check if a snapshot exists for the given session ID."""
    return zfs.snapshot_exists(session_id)


def state_exists(state_name):
    """Check if a state dataset exists."""
    return zfs.dataset_exists(state_name)


def get_slot_state(slot):
    """Get the current state assigned to a slot."""
    assignments_file = "/etc/vm-state-assignments.json"
    if os.path.exists(assignments_file):
        with open(assignments_file) as f:
            assignments = json.load(f)
            return assignments.get(slot, slot)
    return slot


def stop_slot(slot):
    """Stop the microvm slot."""
    logger.info(f"Stopping slot {slot}")
    run_command(["systemctl", "stop", f"microvm@{slot}.service"], check=False)


def start_slot(slot):
    """Start the microvm slot."""
    logger.info(f"Starting slot {slot}")
    run_command(["systemctl", "start", f"microvm@{slot}.service"])


def create_snapshot(slot, snapshot_name):
    """Create a ZFS snapshot of the slot's current state."""
    state = get_slot_state(slot)
    logger.info(f"Creating snapshot {state}@{snapshot_name}")
    zfs.create_snapshot(state, snapshot_name)


def restore_snapshot(session_id, slot):
    """Restore a snapshot to a slot's state."""
    # Find the snapshot
    snapshot = zfs.find_snapshot(session_id)
    if not snapshot:
        raise ValueError(f"Snapshot {session_id} not found")

    # Create a new state from the snapshot
    new_state = f"session-{session_id}"
    mountpoint = f"{STATES_DIR}/{new_state}"

    # Delete existing state if it exists (from previous restore)
    if state_exists(new_state):
        logger.info(f"Deleting existing state {new_state}")
        zfs.destroy_dataset(new_state, recursive=True)

    logger.info(f"Cloning snapshot {snapshot.full_name} to {new_state}")
    zfs.clone_snapshot(snapshot, new_state, mountpoint)

    # Promote to independent dataset
    zfs.promote_dataset(new_state)

    # Set permissions
    run_command(["chown", "microvm:kvm", mountpoint])
    run_command(["chmod", "755", mountpoint])

    # Assign to slot
    assign_state(slot, new_state)


def assign_state(slot, state):
    """Assign a state to a slot."""
    logger.info(f"Assigning state {state} to {slot}")

    # Update assignments file
    assignments_file = "/etc/vm-state-assignments.json"
    assignments = {}
    if os.path.exists(assignments_file):
        with open(assignments_file) as f:
            assignments = json.load(f)

    assignments[slot] = state

    with open(assignments_file, 'w') as f:
        json.dump(assignments, f, indent=2)

    # Create symlink
    slot_dir = f"/var/lib/microvms/{slot}"
    slot_data = f"{slot_dir}/data.img"
    state_data = f"{STATES_DIR}/{state}/data.img"

    os.makedirs(slot_dir, exist_ok=True)

    if os.path.islink(slot_data):
        os.unlink(slot_data)
    elif os.path.exists(slot_data):
        os.rename(slot_data, f"{slot_data}.backup")

    os.symlink(state_data, slot_data)
    logger.info(f"Created symlink: {slot_data} -> {state_data}")


def mount_blank_state(slot):
    """Mount a blank state to the slot."""
    blank_state = f"{BLANK_STATE_PREFIX}{slot}"
    mountpoint = f"{STATES_DIR}/{blank_state}"

    # Create blank state if it doesn't exist
    if not state_exists(blank_state):
        logger.info(f"Creating blank state {blank_state}")
        zfs.create_dataset(blank_state, mountpoint)
        run_command(["chown", "microvm:kvm", mountpoint])
        run_command(["chmod", "755", mountpoint])
    else:
        # Reset blank state by removing data.img
        data_img = f"{mountpoint}/data.img"
        if os.path.exists(data_img):
            logger.info(f"Removing {data_img} to reset blank state")
            os.unlink(data_img)

    assign_state(slot, blank_state)


def handle_borrow(item, params):
    """
    Handle borrow webhook.

    If snapshot exists for sessionId:
        - Restore snapshot to slot
    Otherwise:
        - Mount blank snapshot
        - Create initial snapshot for session
    """
    slot = item.get('id')
    session_id = params.get('sessionId')

    if not slot or not session_id:
        raise ValueError("Missing slot id or sessionId")

    logger.info(f"Handling BORROW: slot={slot}, sessionId={session_id}")

    # Stop the slot first
    stop_slot(slot)

    if snapshot_exists(session_id):
        logger.info(f"Snapshot {session_id} exists, restoring...")
        restore_snapshot(session_id, slot)
    else:
        logger.info(f"No snapshot for {session_id}, mounting blank state...")
        mount_blank_state(slot)

    # Start the slot
    start_slot(slot)

    return {"status": "success", "message": f"Borrowed {slot} for session {session_id}"}


def handle_return(item, params):
    """
    Handle return webhook.

    - Snapshot current state with sessionId
    - Mount blank state
    """
    slot = item.get('id')
    session_id = params.get('sessionId')

    if not slot or not session_id:
        raise ValueError("Missing slot id or sessionId")

    logger.info(f"Handling RETURN: slot={slot}, sessionId={session_id}")

    # Stop the slot first
    stop_slot(slot)

    # Create snapshot of current state
    create_snapshot(slot, session_id)

    # Mount blank state
    mount_blank_state(slot)

    # Start the slot with blank state
    start_slot(slot)

    return {"status": "success", "message": f"Returned {slot}, snapshot saved as {session_id}"}


class SubscriberHandler(BaseHTTPRequestHandler):
    """HTTP request handler for subscriber webhooks."""

    def log_message(self, format, *args):
        logger.info("%s - %s" % (self.address_string(), format % args))

    def send_json_response(self, status_code, data):
        self.send_response(status_code)
        self.send_header('Content-Type', 'application/json')
        self.end_headers()
        self.wfile.write(json.dumps(data).encode())

    def do_GET(self):
        """Handle GET requests (health check)."""
        if self.path == '/health':
            self.send_json_response(200, {"status": "healthy"})
        else:
            self.send_json_response(404, {"error": "Not found"})

    def do_POST(self):
        """Handle POST requests (borrow/return webhooks)."""
        try:
            content_length = int(self.headers.get('Content-Length', 0))
            body = self.rfile.read(content_length)
            data = json.loads(body) if body else {}

            logger.info(f"Received POST {self.path}: {json.dumps(data)}")

            item = data.get('item', {})
            params = data.get('params', {})

            if self.path == '/borrow':
                result = handle_borrow(item, params)
                self.send_json_response(200, result)
            elif self.path == '/return':
                result = handle_return(item, params)
                self.send_json_response(200, result)
            else:
                self.send_json_response(404, {"error": f"Unknown endpoint: {self.path}"})

        except ValueError as e:
            logger.error(f"Validation error: {e}")
            self.send_json_response(400, {"error": str(e)})
        except subprocess.CalledProcessError as e:
            logger.error(f"Command error: {e.stderr}")
            self.send_json_response(500, {"error": f"Command failed: {e.stderr}"})
        except Exception as e:
            logger.error(f"Internal error: {e}")
            self.send_json_response(500, {"error": str(e)})


def main():
    port = int(os.environ.get('PORT', 8081))
    host = os.environ.get('HOST', '127.0.0.1')

    server = HTTPServer((host, port), SubscriberHandler)
    logger.info(f"Slot pool subscriber listening on {host}:{port}")

    try:
        server.serve_forever()
    except KeyboardInterrupt:
        logger.info("Shutting down...")
        server.shutdown()


if __name__ == '__main__':
    main()
