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

      # Enable AOF (Append-Only File) persistence
      appendOnly = true;
      appendFsync = "everysec"; # Options: no, always, everysec

      # Disable RDB snapshots since we're using AOF
      save = [];

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

      # Enable AOF (Append-Only File) persistence
      appendOnly = true;
      appendFsync = "everysec"; # Options: no, always, everysec

      # Disable RDB snapshots since we're using AOF
      save = [];

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
