# modules/monitoring/vector-vm.nix
# Vector configuration for MicroVMs
# Collects journald logs and forwards to hypervisor
{ config, lib, pkgs, ... }:

let
  # Get network configuration to determine VM subnet
  networks = import ../networks.nix;
  vmNetwork = networks.networks.${config.microvm.network};

  # Hypervisor is always at .1 in the VM's subnet
  hypervisorIP = "${vmNetwork.subnet}.1";
in
{
  services.vector = {
    enable = true;
    journaldAccess = true;

    settings = {
      # Source: journald logs
      sources.journald = {
        type = "journald";
        current_boot_only = false;
      };

      # Transform: Add VM-specific labels
      transforms.parse = {
        type = "remap";
        inputs = [ "journald" ];
        source = ''
          .host = "${config.networking.hostName}"
          .role = "microvm"
        '';
      };

      # Sink: Forward logs to hypervisor via syslog
      sinks.hypervisor = {
        type = "syslog";
        inputs = [ "parse" ];
        address = "${hypervisorIP}:514";
        mode = "tcp";
        encoding.codec = "json";
      };
    };
  };
}
