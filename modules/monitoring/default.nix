# modules/monitoring/default.nix
# Main monitoring module for hypervisor
# Enables: Prometheus, Grafana, Loki, Vector, node-exporter
{ config, lib, pkgs, ... }:

{
  imports = [
    ./node-exporter.nix
    ./prometheus.nix
    ./loki.nix
    ./vector-hypervisor.nix
    ./grafana.nix
  ];

  # Ensure monitoring services start in correct order
  systemd.services.vector.after = [ "loki.service" ];
  systemd.services.grafana.after = [ "prometheus.service" "loki.service" ];
}
