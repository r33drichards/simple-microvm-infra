# modules/slot-pool-subscriber.nix
# NixOS module for the slot pool subscriber service
#
# This service handles borrow/return webhooks from ip-allocator-webserver
# to manage VM slot snapshots and state assignments.
{ config, lib, pkgs, ... }:

with lib;

let
  cfg = config.services.slotPoolSubscriber;

  subscriberScript = pkgs.writeScriptBin "slot-pool-subscriber" ''
    #!${pkgs.python3}/bin/python3
    ${builtins.readFile ../scripts/slot-pool-subscriber.py}
  '';
in
{
  options.services.slotPoolSubscriber = {
    enable = mkEnableOption "Slot pool subscriber service for vm snapshot management";

    port = mkOption {
      type = types.port;
      default = 8081;
      description = "Port to listen on for subscriber webhooks";
    };

    address = mkOption {
      type = types.str;
      default = "127.0.0.1";
      description = "Address to bind the subscriber service to";
    };

    openFirewall = mkOption {
      type = types.bool;
      default = false;
      description = "Whether to open the firewall for the subscriber port";
    };
  };

  config = mkIf cfg.enable {
    systemd.services.slot-pool-subscriber = {
      description = "Slot Pool Subscriber - VM snapshot management webhooks";
      wantedBy = [ "multi-user.target" ];
      after = [ "network.target" "zfs.target" ];
      wants = [ "zfs.target" ];

      environment = {
        PORT = toString cfg.port;
        HOST = cfg.address;
      };

      serviceConfig = {
        Type = "simple";
        ExecStart = "${subscriberScript}/bin/slot-pool-subscriber";
        Restart = "always";
        RestartSec = 5;

        # Security hardening
        NoNewPrivileges = false;  # Needs to run systemctl
        ProtectSystem = "strict";
        ReadWritePaths = [
          "/var/lib/microvms"
          "/etc/vm-state-assignments.json"
        ];
        ProtectHome = true;
        PrivateTmp = true;
      };

      path = with pkgs; [
        zfs
        systemd
        coreutils
        util-linux
      ];
    };

    networking.firewall.allowedTCPPorts = mkIf cfg.openFirewall [ cfg.port ];
  };
}
