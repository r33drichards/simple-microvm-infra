# hosts/hypervisor/ip-allocator.nix
# IP/Slot allocator webserver configuration
# Manages a pool of VM slots that can be borrowed/returned with session state
{ config, pkgs, ... }:

let
  subscriberPort = 8081;
in {
  imports = [
    ../../modules/slot-subscriber
  ];

  # Enable the slot subscriber webhook server
  services.slotSubscriber = {
    enable = true;
    port = subscriberPort;
  };

  # Configure ip-allocator-webserver
  services.ip-allocator-webserver = {
    enable = true;
    port = 8000;
    address = "0.0.0.0";

    # Use the Redis instance for ip-allocator
    redisUrl = "redis://127.0.0.1:6379";

    # Configure subscribers for borrow/return events
    subscribers = {
      borrow = {
        subscribers = {
          slot-snapshot = {
            post = "http://127.0.0.1:${toString subscriberPort}/borrow";
            mustSucceed = true;
            async = false;
          };
        };
      };

      return = {
        subscribers = {
          slot-snapshot = {
            post = "http://127.0.0.1:${toString subscriberPort}/return";
            mustSucceed = true;
            async = false;
          };
        };
      };
    };
  };

  # Open firewall for ip-allocator API (optional - only if external access needed)
  # networking.firewall.allowedTCPPorts = [ 8000 ];
}
