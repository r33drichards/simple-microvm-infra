# modules/networks.nix
# Network topology definitions for 4 isolated MicroVMs
# Each VM gets its own bridge and subnet
{
  networks = {
    vm1 = {
      subnet = "10.1.0";
      bridge = "br-vm1";
    };
    vm2 = {
      subnet = "10.2.0";
      bridge = "br-vm2";
    };
    vm3 = {
      subnet = "10.3.0";
      bridge = "br-vm3";
    };
    vm4 = {
      subnet = "10.4.0";
      bridge = "br-vm4";
    };
  };
}
