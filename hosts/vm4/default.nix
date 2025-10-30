# hosts/vm4/default.nix
# MicroVM 4 configuration
# Network: 10.4.0.2/24 (bridge: br-vm4)

import ../../lib/create-vm.nix {
  hostname = "vm4";
  network = "vm4";
}
