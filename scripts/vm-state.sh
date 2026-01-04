#!/usr/bin/env bash
# vm-state - Manage portable VM states
#
# Portable State Architecture:
# - Slots are fixed network identities (slot1 = 10.1.0.2, etc.)
# - States are portable ZFS datasets that can be snapshotted and migrated
# - Any state can run on any slot
#
# Usage:
#   vm-state list                    - List all states and their assignments
#   vm-state create <name>           - Create a new empty state
#   vm-state snapshot <slot> <name>  - Snapshot current slot state as <name>
#   vm-state assign <slot> <state>   - Assign a state to a slot (requires restart)
#   vm-state clone <src> <dst>       - Clone a state to a new name
#   vm-state delete <name>           - Delete a state (must not be in use)
#   vm-state migrate <state> <slot>  - Stop slot, assign state, start slot

set -euo pipefail

# Configuration
STATES_DIR="/var/lib/microvms/states"
ASSIGNMENTS_FILE="/etc/vm-state-assignments.json"
ZFS_POOL="microvms"
ZFS_DATASET="storage/states"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Helper functions
info() { echo -e "${BLUE}[INFO]${NC} $*"; }
success() { echo -e "${GREEN}[OK]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }
die() { error "$*"; exit 1; }

# Ensure we're running as root
check_root() {
  if [[ $EUID -ne 0 ]]; then
    die "This script must be run as root"
  fi
}

# Get state assigned to a slot from assignments file
get_slot_state() {
  local slot=$1
  if [[ -f "$ASSIGNMENTS_FILE" ]]; then
    jq -r --arg slot "$slot" '.[$slot] // $slot' "$ASSIGNMENTS_FILE"
  else
    # Default: slot uses state with same name
    echo "$slot"
  fi
}

# Set state assignment for a slot
set_slot_state() {
  local slot=$1
  local state=$2

  # Create assignments file if it doesn't exist
  if [[ ! -f "$ASSIGNMENTS_FILE" ]]; then
    echo '{}' > "$ASSIGNMENTS_FILE"
  fi

  # Update assignment
  jq --arg slot "$slot" --arg state "$state" '.[$slot] = $state' \
    "$ASSIGNMENTS_FILE" > "${ASSIGNMENTS_FILE}.tmp"
  mv "${ASSIGNMENTS_FILE}.tmp" "$ASSIGNMENTS_FILE"
}

# Check if a slot is running
is_slot_running() {
  local slot=$1
  systemctl is-active "microvm@${slot}.service" &>/dev/null
}

# List all states and assignments
cmd_list() {
  info "States and assignments:"
  echo ""
  printf "%-15s %-15s %-10s %s\n" "SLOT" "STATE" "RUNNING" "ZFS DATASET"
  printf "%-15s %-15s %-10s %s\n" "----" "-----" "-------" "-----------"

  for slot in slot1 slot2 slot3 slot4 slot5; do
    local state=$(get_slot_state "$slot")
    local running="no"
    is_slot_running "$slot" && running="yes"
    local dataset="${ZFS_POOL}/${ZFS_DATASET}/${state}"

    printf "%-15s %-15s %-10s %s\n" "$slot" "$state" "$running" "$dataset"
  done

  echo ""
  info "Available states (ZFS datasets):"
  if zfs list -H -o name -r "${ZFS_POOL}/${ZFS_DATASET}" 2>/dev/null | grep -v "^${ZFS_POOL}/${ZFS_DATASET}$"; then
    zfs list -H -o name,used,avail -r "${ZFS_POOL}/${ZFS_DATASET}" 2>/dev/null | \
      grep -v "^${ZFS_POOL}/${ZFS_DATASET}\s" | \
      while read -r name used avail; do
        state_name=$(basename "$name")
        printf "  %-20s used: %-8s avail: %s\n" "$state_name" "$used" "$avail"
      done
  else
    echo "  (no states created yet)"
  fi

  echo ""
  info "Snapshots:"
  if zfs list -H -t snapshot -o name -r "${ZFS_POOL}/${ZFS_DATASET}" 2>/dev/null | head -20; then
    :
  else
    echo "  (no snapshots)"
  fi
}

# Create a new empty state
cmd_create() {
  local name=${1:-}
  [[ -z "$name" ]] && die "Usage: vm-state create <name>"

  local dataset="${ZFS_POOL}/${ZFS_DATASET}/${name}"

  # Check if state already exists
  if zfs list -H "$dataset" &>/dev/null; then
    die "State '$name' already exists"
  fi

  info "Creating state '$name'..."

  # Create ZFS dataset
  zfs create -o mountpoint="${STATES_DIR}/${name}" "$dataset"

  # Set permissions
  chown microvm:kvm "${STATES_DIR}/${name}"
  chmod 755 "${STATES_DIR}/${name}"

  success "State '$name' created at ${STATES_DIR}/${name}"
  info "Assign it to a slot with: vm-state assign <slot> $name"
}

# Snapshot current slot state
cmd_snapshot() {
  local slot=${1:-}
  local snapshot_name=${2:-}

  [[ -z "$slot" || -z "$snapshot_name" ]] && die "Usage: vm-state snapshot <slot> <snapshot-name>"

  local state=$(get_slot_state "$slot")
  local dataset="${ZFS_POOL}/${ZFS_DATASET}/${state}"

  # Check if state exists
  if ! zfs list -H "$dataset" &>/dev/null; then
    die "State '$state' (assigned to $slot) doesn't exist as ZFS dataset"
  fi

  info "Creating snapshot of state '$state' (from $slot)..."

  # Optionally stop the VM for a consistent snapshot
  if is_slot_running "$slot"; then
    warn "$slot is running - snapshot will be crash-consistent"
    warn "For a clean snapshot, stop the slot first: systemctl stop microvm@$slot"
  fi

  # Create snapshot
  zfs snapshot "${dataset}@${snapshot_name}"

  success "Snapshot created: ${dataset}@${snapshot_name}"
}

# Assign a state to a slot
cmd_assign() {
  local slot=${1:-}
  local state=${2:-}

  [[ -z "$slot" || -z "$state" ]] && die "Usage: vm-state assign <slot> <state>"

  # Validate slot name
  if [[ ! "$slot" =~ ^slot[1-5]$ ]]; then
    die "Invalid slot name '$slot'. Must be slot1-slot5."
  fi

  # Check if state exists (as directory or ZFS dataset)
  local state_dir="${STATES_DIR}/${state}"
  local dataset="${ZFS_POOL}/${ZFS_DATASET}/${state}"

  if [[ ! -d "$state_dir" ]] && ! zfs list -H "$dataset" &>/dev/null; then
    warn "State '$state' doesn't exist yet. Creating it..."
    cmd_create "$state"
  fi

  # Check if slot is running
  if is_slot_running "$slot"; then
    warn "$slot is currently running. Assignment will take effect after restart."
  fi

  # Update assignment
  set_slot_state "$slot" "$state"

  success "Assigned state '$state' to $slot"

  if is_slot_running "$slot"; then
    info "Restart the slot to use the new state: systemctl restart microvm@$slot"
  else
    info "Start the slot with: systemctl start microvm@$slot"
  fi
}

# Clone a state to a new name
cmd_clone() {
  local src=${1:-}
  local dst=${2:-}

  [[ -z "$src" || -z "$dst" ]] && die "Usage: vm-state clone <source-state> <destination-state>"

  local src_dataset="${ZFS_POOL}/${ZFS_DATASET}/${src}"
  local dst_dataset="${ZFS_POOL}/${ZFS_DATASET}/${dst}"

  # Check source exists
  if ! zfs list -H "$src_dataset" &>/dev/null; then
    die "Source state '$src' doesn't exist"
  fi

  # Check destination doesn't exist
  if zfs list -H "$dst_dataset" &>/dev/null; then
    die "Destination state '$dst' already exists"
  fi

  info "Cloning state '$src' to '$dst'..."

  # Create a snapshot for the clone
  local clone_snap="${src_dataset}@clone-for-${dst}"
  zfs snapshot "$clone_snap"

  # Clone from snapshot
  zfs clone -o mountpoint="${STATES_DIR}/${dst}" "$clone_snap" "$dst_dataset"

  # Promote the clone to a full dataset (no longer depends on snapshot)
  zfs promote "$dst_dataset"

  # Set permissions
  chown microvm:kvm "${STATES_DIR}/${dst}"
  chmod 755 "${STATES_DIR}/${dst}"

  success "State '$src' cloned to '$dst'"
  info "Assign it to a slot with: vm-state assign <slot> $dst"
}

# Delete a state
cmd_delete() {
  local name=${1:-}
  [[ -z "$name" ]] && die "Usage: vm-state delete <name>"

  local dataset="${ZFS_POOL}/${ZFS_DATASET}/${name}"

  # Check if state exists
  if ! zfs list -H "$dataset" &>/dev/null; then
    die "State '$name' doesn't exist"
  fi

  # Check if state is in use by any slot
  for slot in slot1 slot2 slot3 slot4 slot5; do
    local assigned=$(get_slot_state "$slot")
    if [[ "$assigned" == "$name" ]]; then
      die "State '$name' is assigned to $slot. Reassign first with: vm-state assign $slot <other-state>"
    fi
  done

  warn "This will permanently delete state '$name' and all its data!"
  read -p "Type 'DELETE' to confirm: " confirm

  if [[ "$confirm" != "DELETE" ]]; then
    die "Aborted"
  fi

  info "Deleting state '$name'..."

  # Delete all snapshots first
  zfs list -H -t snapshot -o name -r "$dataset" 2>/dev/null | while read -r snap; do
    zfs destroy "$snap"
  done

  # Delete the dataset
  zfs destroy "$dataset"

  success "State '$name' deleted"
}

# Migrate: stop slot, assign state, start slot
cmd_migrate() {
  local state=${1:-}
  local slot=${2:-}

  [[ -z "$state" || -z "$slot" ]] && die "Usage: vm-state migrate <state> <slot>"

  info "Migrating state '$state' to $slot..."

  # Stop the slot if running
  if is_slot_running "$slot"; then
    info "Stopping $slot..."
    systemctl stop "microvm@${slot}.service"
    sleep 2
  fi

  # Assign the state
  cmd_assign "$slot" "$state"

  # Start the slot
  info "Starting $slot with state '$state'..."
  systemctl start "microvm@${slot}.service"

  success "Migration complete. $slot is now running state '$state'"
}

# Restore a snapshot to a new state
cmd_restore() {
  local snapshot=${1:-}
  local new_state=${2:-}

  [[ -z "$snapshot" || -z "$new_state" ]] && die "Usage: vm-state restore <snapshot-name> <new-state-name>"

  # Find the snapshot
  local full_snapshot=""
  while IFS= read -r snap; do
    if [[ "$snap" == *"@${snapshot}" ]]; then
      full_snapshot="$snap"
      break
    fi
  done < <(zfs list -H -t snapshot -o name -r "${ZFS_POOL}/${ZFS_DATASET}" 2>/dev/null)

  [[ -z "$full_snapshot" ]] && die "Snapshot '$snapshot' not found"

  local dst_dataset="${ZFS_POOL}/${ZFS_DATASET}/${new_state}"

  # Check destination doesn't exist
  if zfs list -H "$dst_dataset" &>/dev/null; then
    die "State '$new_state' already exists"
  fi

  info "Restoring snapshot '$full_snapshot' to state '$new_state'..."

  # Clone from snapshot
  zfs clone -o mountpoint="${STATES_DIR}/${new_state}" "$full_snapshot" "$dst_dataset"

  # Promote to full dataset
  zfs promote "$dst_dataset"

  # Set permissions
  chown microvm:kvm "${STATES_DIR}/${new_state}"
  chmod 755 "${STATES_DIR}/${new_state}"

  success "Snapshot restored to state '$new_state'"
  info "Assign it to a slot with: vm-state assign <slot> $new_state"
}

# Show help
cmd_help() {
  cat <<EOF
vm-state - Manage portable VM states

USAGE:
  vm-state <command> [arguments]

COMMANDS:
  list                        List all states and slot assignments
  create <name>               Create a new empty state
  snapshot <slot> <name>      Snapshot current slot's state
  assign <slot> <state>       Assign a state to a slot
  clone <source> <dest>       Clone a state to a new name
  delete <name>               Delete a state (must not be in use)
  migrate <state> <slot>      Stop slot, assign state, start slot
  restore <snapshot> <state>  Restore a snapshot to a new state
  help                        Show this help

EXAMPLES:
  # List all states
  vm-state list

  # Create a new development environment
  vm-state create dev-env

  # Snapshot slot1's current state
  vm-state snapshot slot1 before-update

  # Run the dev-env state on slot2
  vm-state assign slot2 dev-env
  systemctl restart microvm@slot2

  # Clone production to test
  vm-state clone prod-env test-env
  vm-state migrate test-env slot3

  # Restore a snapshot
  vm-state restore before-update recovered-state

ARCHITECTURE:
  Slots are fixed network identities:
    slot1 = 10.1.0.2, slot2 = 10.2.0.2, ..., slot5 = 10.5.0.2

  States are portable persistent data stored as ZFS datasets:
    /var/lib/microvms/states/<state-name>/

  Any state can run on any slot. States can be:
    - Snapshotted for backup/rollback
    - Cloned for experimentation
    - Migrated between slots
EOF
}

# Main entry point
main() {
  check_root

  local cmd=${1:-list}
  shift || true

  case "$cmd" in
    list)     cmd_list "$@" ;;
    create)   cmd_create "$@" ;;
    snapshot) cmd_snapshot "$@" ;;
    assign)   cmd_assign "$@" ;;
    clone)    cmd_clone "$@" ;;
    delete)   cmd_delete "$@" ;;
    migrate)  cmd_migrate "$@" ;;
    restore)  cmd_restore "$@" ;;
    help|--help|-h) cmd_help ;;
    *) die "Unknown command: $cmd. Use 'vm-state help' for usage." ;;
  esac
}

main "$@"
