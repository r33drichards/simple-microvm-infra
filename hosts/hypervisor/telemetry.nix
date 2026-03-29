# hosts/hypervisor/telemetry.nix
# Host telemetry stack: Prometheus + Node Exporter + Loki + Promtail + Grafana
# Collects all systemd service logs and host metrics
# Queryable from slots via bridge IPs (e.g., slot1 → http://10.1.0.1:3000)
{ config, pkgs, lib, ... }:

{
  # Prometheus: metrics storage and query engine (port 9090)
  services.prometheus = {
    enable = true;
    port = 9090;
    listenAddress = "0.0.0.0";
    retentionTime = "30d";

    exporters.node = {
      enable = true;
      port = 9100;
      listenAddress = "0.0.0.0";
      enabledCollectors = [
        "systemd"
        "processes"
        "cpu"
        "diskstats"
        "filesystem"
        "loadavg"
        "meminfo"
        "netdev"
        "stat"
        "time"
        "uname"
        "vmstat"
      ];
    };

    scrapeConfigs = [
      {
        job_name = "node";
        static_configs = [{
          targets = [ "localhost:9100" ];
          labels = { instance = "hypervisor"; };
        }];
        scrape_interval = "15s";
      }
      {
        job_name = "prometheus";
        static_configs = [{
          targets = [ "localhost:9090" ];
        }];
        scrape_interval = "30s";
      }
    ];
  };

  # Loki: log aggregation (port 3100)
  services.loki = {
    enable = true;
    configuration = {
      server = {
        http_listen_port = 3100;
        http_listen_address = "0.0.0.0";
      };

      auth_enabled = false;

      common = {
        path_prefix = "/var/lib/loki";
        ring = {
          instance_addr = "127.0.0.1";
          kvstore.store = "inmemory";
        };
        replication_factor = 1;
      };

      schema_config.configs = [{
        from = "2024-01-01";
        store = "tsdb";
        object_store = "filesystem";
        schema = "v13";
        index = {
          prefix = "index_";
          period = "24h";
        };
      }];

      storage_config.filesystem.directory = "/var/lib/loki/chunks";

      limits_config = {
        retention_period = "720h"; # 30 days
        allow_structured_metadata = false;
      };

      compactor = {
        working_directory = "/var/lib/loki/compactor";
        compaction_interval = "10m";
        retention_enabled = true;
        retention_delete_delay = "2h";
        delete_request_store = "filesystem";
      };
    };
  };

  # Promtail: ships journald logs to Loki
  services.promtail = {
    enable = true;
    configuration = {
      server = {
        http_listen_port = 9080;
        grpc_listen_port = 0;
      };

      positions.filename = "/var/lib/promtail/positions.yaml";

      clients = [{
        url = "http://localhost:3100/loki/api/v1/push";
      }];

      scrape_configs = [{
        job_name = "journal";
        journal = {
          max_age = "12h";
          labels = {
            job = "systemd-journal";
            host = "hypervisor";
          };
        };
        relabel_configs = [
          {
            source_labels = [ "__journal__systemd_unit" ];
            target_label = "unit";
          }
          {
            source_labels = [ "__journal_priority_keyword" ];
            target_label = "level";
          }
          {
            source_labels = [ "__journal__hostname" ];
            target_label = "hostname";
          }
          {
            source_labels = [ "__journal_syslog_identifier" ];
            target_label = "syslog_identifier";
          }
        ];
      }];
    };
  };

  # Grafana: dashboard UI (port 3000)
  services.grafana = {
    enable = true;
    settings = {
      server = {
        http_addr = "0.0.0.0";
        http_port = 3000;
      };
      # Allow anonymous read access from slots
      "auth.anonymous" = {
        enabled = true;
        org_role = "Viewer";
      };
      security = {
        admin_user = "admin";
        admin_password = "admin";
      };
    };

    provision = {
      datasources.settings.datasources = [
        {
          name = "Prometheus";
          type = "prometheus";
          access = "proxy";
          url = "http://localhost:9090";
          isDefault = true;
        }
        {
          name = "Loki";
          type = "loki";
          access = "proxy";
          url = "http://localhost:3100";
        }
      ];
    };
  };
}
