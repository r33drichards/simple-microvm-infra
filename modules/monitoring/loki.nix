# modules/monitoring/loki.nix
# Loki log aggregation server for hypervisor
{ config, lib, pkgs, ... }:

{
  services.loki = {
    enable = true;
    configuration = {
      server.http_listen_port = 3100;
      auth_enabled = false;

      ingester = {
        lifecycler = {
          address = "127.0.0.1";
          ring = {
            kvstore = {
              store = "inmemory";
            };
            replication_factor = 1;
          };
        };
        chunk_idle_period = "1h";
        max_chunk_age = "1h";
        chunk_target_size = 999999;
        chunk_retain_period = "30s";
      };

      schema_config = {
        configs = [{
          from = "2024-01-01";
          store = "tsdb";
          object_store = "filesystem";
          schema = "v13";
          index = {
            prefix = "index_";
            period = "24h";
          };
        }];
      };

      storage_config = {
        tsdb_shipper = {
          active_index_directory = "/var/lib/loki/tsdb-index";
          cache_location = "/var/lib/loki/tsdb-cache";
        };
        filesystem = {
          directory = "/var/lib/loki/chunks";
        };
      };

      limits_config = {
        reject_old_samples = true;
        reject_old_samples_max_age = "168h";
        allow_structured_metadata = false;
      };

      table_manager = {
        retention_deletes_enabled = true;
        retention_period = "336h";  # 14 days
      };

      compactor = {
        working_directory = "/var/lib/loki/compactor";
        compaction_interval = "10m";
        retention_enabled = true;
        retention_delete_delay = "2h";
        retention_delete_worker_count = 150;
      };
    };
  };

  # Open firewall for Loki
  networking.firewall.allowedTCPPorts = [ 3100 ];

  # Ensure Loki state directory has proper permissions
  systemd.tmpfiles.rules = [
    "d /var/lib/loki 0700 loki loki -"
    "d /var/lib/loki/chunks 0700 loki loki -"
    "d /var/lib/loki/tsdb-index 0700 loki loki -"
    "d /var/lib/loki/tsdb-cache 0700 loki loki -"
    "d /var/lib/loki/compactor 0700 loki loki -"
  ];
}
