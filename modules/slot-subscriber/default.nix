# modules/slot-subscriber/default.nix
# HTTP webhook subscriber for ip-allocator borrow/return events
# Manages ZFS snapshots for session state isolation
{ config, pkgs, lib, ... }:

with lib;

let
  cfg = config.services.slotSubscriber;

  # Python webhook server script
  serverScript = ./server.py;

in {
  options.services.slotSubscriber = {
    enable = mkEnableOption "Slot subscriber webhook server";

    port = mkOption {
      type = types.port;
      default = 8081;
      description = "Port for the subscriber webhook server";
    };
  };

  config = mkIf cfg.enable {
    systemd.services.slot-subscriber = {
      description = "Slot Subscriber Webhook Server";
      after = [ "network.target" "zfs.target" ];
      wants = [ "zfs.target" ];
      wantedBy = [ "multi-user.target" ];

      environment = {
        SUBSCRIBER_PORT = toString cfg.port;
      };

      serviceConfig = {
        Type = "simple";
        ExecStart = "${pkgs.python3}/bin/python3 ${serverScript}";
        Restart = "always";
        RestartSec = 5;

        # Run as root to manage VMs and ZFS
        # Could be locked down with specific capabilities if needed
      };
    };
  };
}
