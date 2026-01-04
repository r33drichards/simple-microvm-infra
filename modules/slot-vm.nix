# modules/slot-vm.nix
# Unified VM configuration for portable state architecture
# All slots use the same packages/capabilities - state is what differs
#
# Key concepts:
# - "Slot" = network identity (slot1 = 10.1.0.2, slot2 = 10.2.0.2, etc.)
# - "State" = persistent data (named ZFS datasets that can be snapshotted/migrated)
# - States can be transferred between slots via snapshots
#
# Boot-time identity:
# - Slot number determines network config (IP, bridge, MAC)
# - Hostname is set dynamically based on slot
# - State is mounted by hypervisor before VM boot
{ config, lib, pkgs, ... }:

{
  # Enable SSH for remote access
  services.openssh.enable = true;

  # Unified package set - superset of all VM types
  # This ensures any state can run on any slot
  environment.systemPackages = with pkgs; [
    # Basic tools
    vim
    curl
    htop
    git
    wget
    tmux
    jq
    tree
    file
    unzip
    rsync

    # Network tools
    iproute2
    iputils
    netcat
    tcpdump

    # Development tools
    nodejs
    python3

    # Container/VM tools (for states that need them)
    # docker  # Uncomment if needed
  ];

  # Create robertwendt user
  users.users.robertwendt = {
    isNormalUser = true;
    extraGroups = [ "wheel" "docker" ];
    openssh.authorizedKeys.keys = [
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIHJNEMM9i3WgPeA5dDmU7KMWTCcwLLi4EWfX8CKXuK7s robertwendt@Roberts-Laptop.local"
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGgfMmLS077IliGfXWUHTzI9ZBWFm6Vkn4m+NXvlmmOw root@ip-172-31-22-108.ec2.internal"
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAINlI6KJHGNUzVJV/OpBQPrcXQkYylvhoM3XvWJI1/tiZ"
    ];
  };

  # Systemd service to configure identity at boot
  # Reads slot number and configures hostname accordingly
  systemd.services.configure-slot-identity = {
    description = "Configure VM identity based on slot assignment";
    wantedBy = [ "multi-user.target" ];
    before = [ "network.target" ];
    after = [ "local-fs.target" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script = ''
      # Read slot assignment from file (created by hypervisor before boot)
      SLOT_FILE="/etc/vm-slot"
      STATE_FILE="/etc/vm-state"

      if [ -f "$SLOT_FILE" ]; then
        SLOT=$(cat "$SLOT_FILE")
        echo "Configured as slot: $SLOT"
      else
        # Default to slot from hostname if no override
        SLOT=$(hostname | sed 's/slot//')
        echo "No slot file, using hostname-derived slot: $SLOT"
      fi

      if [ -f "$STATE_FILE" ]; then
        STATE=$(cat "$STATE_FILE")
        echo "Running state: $STATE"
      fi

      # Log the configuration
      echo "VM Identity: slot=$SLOT state=$STATE" > /run/vm-identity
    '';
  };

  # NixOS version
  system.stateVersion = "24.05";
}
