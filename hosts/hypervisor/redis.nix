# hosts/hypervisor/redis.nix
# Redis services on hypervisor
{ config, pkgs, ... }:
{
  # Enable Redis with two separate instances
  services.redis.servers = {
    # Redis instance for IP allocator
    ip-allocator = {
      enable = true;
      port = 6379;
      bind = "127.0.0.1";

      # Enable AOF (Append-Only File) persistence for durability
      appendOnly = true;
      appendFsync = "everysec"; # Options: no, always, everysec

      # Enable RDB snapshots for fast restarts and backups
      save = [
        [900 1]      # Save after 900 seconds (15 min) if at least 1 key changed
        [300 10]     # Save after 300 seconds (5 min) if at least 10 keys changed
        [60 10000]   # Save after 60 seconds (1 min) if at least 10000 keys changed
      ];

      # Additional settings for reliability
      settings = {
        # AOF rewrite settings
        auto-aof-rewrite-percentage = 100;
        auto-aof-rewrite-min-size = "64mb";

        # Ensure AOF is loaded on startup
        aof-load-truncated = "yes";
      };
    };

    # Redis instance for job queue
    job-queue = {
      enable = true;
      port = 6380;
      bind = "127.0.0.1";

      # Enable AOF (Append-Only File) persistence for durability
      appendOnly = true;
      appendFsync = "everysec"; # Options: no, always, everysec

      # Enable RDB snapshots for fast restarts and backups
      save = [
        [900 1]      # Save after 900 seconds (15 min) if at least 1 key changed
        [300 10]     # Save after 300 seconds (5 min) if at least 10 keys changed
        [60 10000]   # Save after 60 seconds (1 min) if at least 10000 keys changed
      ];

      # Additional settings for reliability
      settings = {
        # AOF rewrite settings
        auto-aof-rewrite-percentage = 100;
        auto-aof-rewrite-min-size = "64mb";

        # Ensure AOF is loaded on startup
        aof-load-truncated = "yes";
      };
    };
  };
}
