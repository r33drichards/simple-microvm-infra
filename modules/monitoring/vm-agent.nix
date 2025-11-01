# modules/monitoring/vm-agent.nix
# Monitoring agent for MicroVMs
# Enables: node-exporter, Vector log forwarding
{ config, lib, pkgs, ... }:

{
  imports = [
    ./node-exporter.nix
    ./vector-vm.nix
  ];
}
