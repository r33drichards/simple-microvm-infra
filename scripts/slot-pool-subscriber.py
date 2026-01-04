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
    result = run_command([
        "zfs", "list", "-H", "-t", "snapshot", "-o", "name",
        "-r", f"{ZFS_POOL}/{ZFS_DATASET}"
    ], check=False)

    if result.returncode != 0:
        return False

    for line in result.stdout.strip().split('\n'):
        if line.endswith(f"@{session_id}"):
            return True
    return False


def state_exists(state_name):
    """Check if a state dataset exists."""
    result = run_command([
        "zfs", "list", "-H", f"{ZFS_POOL}/{ZFS_DATASET}/{state_name}"
    ], check=False)
    return result.returncode == 0


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
    dataset = f"{ZFS_POOL}/{ZFS_DATASET}/{state}"

    logger.info(f"Creating snapshot {dataset}@{snapshot_name}")
    run_command(["zfs", "snapshot", f"{dataset}@{snapshot_name}"])


def restore_snapshot(session_id, slot):
    """Restore a snapshot to a slot's state."""
    # Find the full snapshot path
    result = run_command([
        "zfs", "list", "-H", "-t", "snapshot", "-o", "name",
        "-r", f"{ZFS_POOL}/{ZFS_DATASET}"
    ])

    full_snapshot = None
    for line in result.stdout.strip().split('\n'):
        if line.endswith(f"@{session_id}"):
            full_snapshot = line
            break

    if not full_snapshot:
        raise ValueError(f"Snapshot {session_id} not found")

    # Create a new state from the snapshot
    new_state = f"session-{session_id}"
    new_dataset = f"{ZFS_POOL}/{ZFS_DATASET}/{new_state}"

    # Delete existing state if it exists (from previous restore)
    if state_exists(new_state):
        logger.info(f"Deleting existing state {new_state}")
        run_command(["zfs", "destroy", "-r", new_dataset])

    logger.info(f"Cloning snapshot {full_snapshot} to {new_state}")
    run_command([
        "zfs", "clone",
        "-o", f"mountpoint={STATES_DIR}/{new_state}",
        full_snapshot, new_dataset
    ])

    # Promote to independent dataset
    run_command(["zfs", "promote", new_dataset])

    # Set permissions
    run_command(["chown", "microvm:kvm", f"{STATES_DIR}/{new_state}"])
    run_command(["chmod", "755", f"{STATES_DIR}/{new_state}"])

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

    # Create blank state if it doesn't exist
    if not state_exists(blank_state):
        logger.info(f"Creating blank state {blank_state}")
        dataset = f"{ZFS_POOL}/{ZFS_DATASET}/{blank_state}"
        run_command([
            "zfs", "create",
            "-o", f"mountpoint={STATES_DIR}/{blank_state}",
            dataset
        ])
        run_command(["chown", "microvm:kvm", f"{STATES_DIR}/{blank_state}"])
        run_command(["chmod", "755", f"{STATES_DIR}/{blank_state}"])
    else:
        # Reset blank state by removing data.img
        data_img = f"{STATES_DIR}/{blank_state}/data.img"
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
