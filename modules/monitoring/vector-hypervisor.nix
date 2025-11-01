# modules/monitoring/vector-hypervisor.nix
# Vector configuration for hypervisor
# Collects local logs and receives logs from VMs
{ config, lib, pkgs, ... }:

{
  services.vector = {
    enable = true;
    journaldAccess = true;

    settings = {
      # Source: journald logs from hypervisor
      sources = {
        journald = {
          type = "journald";
          current_boot_only = false;
        };

        # Receive logs from VMs via syslog protocol
        vm_logs = {
          type = "syslog";
          address = "0.0.0.0:514";
          mode = "tcp";
        };
      };

      # Transform: Add hypervisor-specific labels
      transforms = {
        parse_hypervisor = {
          type = "remap";
          inputs = [ "journald" ];
          source = ''
            .host = "hypervisor"
            .role = "host"
          '';
        };

        parse_vm_logs = {
          type = "remap";
          inputs = [ "vm_logs" ];
          source = ''
            .role = "microvm"
          '';
        };
      };

      # Sink: Forward all logs to Loki
      sinks = {
        loki = {
          type = "loki";
          inputs = [ "parse_hypervisor" "parse_vm_logs" ];
          endpoint = "http://localhost:3100";
          encoding.codec = "json";
          labels = {
            host = "{{ host }}";
            role = "{{ role }}";
          };
        };

        # Also output to console for debugging (optional)
        console = {
          type = "console";
          inputs = [ "parse_hypervisor" "parse_vm_logs" ];
          encoding.codec = "json";
        };
      };
    };
  };

  # Open firewall for Vector syslog receiver
  networking.firewall.allowedTCPPorts = [ 514 ];
}
