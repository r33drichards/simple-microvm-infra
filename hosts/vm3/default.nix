# hosts/vm3/default.nix
# MicroVM 3 configuration
# Network: 10.3.0.2/24 (bridge: br-vm3)

import ../../lib/create-vm.nix {
  hostname = "vm3";
  network = "vm3";
}
