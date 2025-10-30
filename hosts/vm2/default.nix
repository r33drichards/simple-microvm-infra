# hosts/vm2/default.nix
# MicroVM 2 configuration
# Network: 10.2.0.2/24 (bridge: br-vm2)

import ../../lib/create-vm.nix {
  hostname = "vm2";
  network = "vm2";
}
