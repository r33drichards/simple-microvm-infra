# Centralized VM Resource Configuration
# This module defines default CPU and memory allocations for all VMs.
# Individual VMs can override these settings if needed.

{ lib, ... }:

{
  options = {
    vmDefaults = {
      vcpu = lib.mkOption {
        type = lib.types.int;
        default = 3;
        description = "Default number of virtual CPUs for VMs";
      };

      mem = lib.mkOption {
        type = lib.types.int;
        default = 6144;  # 6 GB in MB
        description = "Default memory allocation for VMs in MB";
      };
    };
  };

  config = {
    # Set the defaults that will be used by all VMs
    vmDefaults = {
      vcpu = 3;
      mem = 6144;  # 6 GB
    };
  };
}
