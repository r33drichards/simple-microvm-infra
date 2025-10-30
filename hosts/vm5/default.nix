# hosts/vm5/default.nix
# MicroVM 5 configuration
# Network: 10.5.0.2/24 (bridge: br-vm5)

import ../../lib/create-vm.nix {
  hostname = "vm5";
  network = "vm5";
}
