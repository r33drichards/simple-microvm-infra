# hosts/vm1/default.nix
# MicroVM 1 configuration
# Network: 10.1.0.2/24 (bridge: br-vm1)

import ../../lib/create-vm.nix {
  hostname = "vm1";
  network = "vm1";

  # Optional: Add custom modules for VM-specific configuration
  # modules = [ ./custom-config.nix ];

  # Optional: Add extra packages beyond the defaults (vim, curl, htop)
  # packages = with pkgs; [ git docker ];

  # Optional: Override resource allocation
  # modules = [{ microvm.vcpu = 4; microvm.mem = 8192; }];
}
