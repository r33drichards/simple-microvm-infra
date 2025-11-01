# modules/monitoring/node-exporter.nix
# Prometheus node-exporter for system metrics
# Used by both hypervisor and VMs
{ config, lib, pkgs, ... }:

{
  services.prometheus.exporters.node = {
    enable = true;
    port = 9100;
    # Enable all collectors by default
    enabledCollectors = [
      "systemd"
      "processes"
      "interrupts"
      "tcpstat"
    ];
    # Disable collectors that don't work in VMs
    disabledCollectors = [
      "rapl"  # RAPL not available in VMs
    ];
  };

  # Open firewall for node-exporter
  networking.firewall.allowedTCPPorts = [ 9100 ];
}
