# modules/networks.nix
# Network topology definitions for VM slots
# Each slot gets its own bridge and subnet
#
# Portable State Architecture:
# - Slots are fixed network identities (slot1 = 10.1.0.0/24, etc.)
# - States are portable data that can be mounted to any slot
# - When state "foo" runs on slot1, it gets IP 10.1.0.2
{
  # Slot-based network definitions
  # slotN = network identity with fixed IP range
  networks = {
    slot1 = {
      subnet = "10.1.0";
      bridge = "br-slot1";
    };
    slot2 = {
      subnet = "10.2.0";
      bridge = "br-slot2";
    };
    slot3 = {
      subnet = "10.3.0";
      bridge = "br-slot3";
    };
    slot4 = {
      subnet = "10.4.0";
      bridge = "br-slot4";
    };
    slot5 = {
      subnet = "10.5.0";
      bridge = "br-slot5";
    };
  };

  # Helper to get slot number from slot name
  slotNumber = name: builtins.substring 4 1 name;  # "slot1" -> "1"
}
