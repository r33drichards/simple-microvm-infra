# modules/monitoring/prometheus.nix
# Prometheus server configuration for hypervisor
{ config, lib, pkgs, ... }:

{
  services.prometheus = {
    enable = true;
    port = 9090;

    # Retention settings
    retentionTime = "15d";

    # Scrape configuration
    scrapeConfigs = [
      {
        job_name = "hypervisor";
        static_configs = [{
          targets = [ "localhost:9100" ];
          labels = {
            instance = "hypervisor";
            role = "host";
          };
        }];
        scrape_interval = "15s";
      }
      {
        job_name = "microvms";
        static_configs = [
          {
            targets = [ "10.1.0.2:9100" ];
            labels = {
              instance = "vm1";
              role = "microvm";
            };
          }
          {
            targets = [ "10.2.0.2:9100" ];
            labels = {
              instance = "vm2";
              role = "microvm";
            };
          }
          {
            targets = [ "10.3.0.2:9100" ];
            labels = {
              instance = "vm3";
              role = "microvm";
            };
          }
          {
            targets = [ "10.4.0.2:9100" ];
            labels = {
              instance = "vm4";
              role = "microvm";
            };
          }
          {
            targets = [ "10.5.0.2:9100" ];
            labels = {
              instance = "vm5";
              role = "microvm";
            };
          }
        ];
        scrape_interval = "15s";
      }
      {
        job_name = "prometheus";
        static_configs = [{
          targets = [ "localhost:9090" ];
          labels = {
            instance = "hypervisor";
            role = "prometheus";
          };
        }];
        scrape_interval = "15s";
      }
      {
        job_name = "loki";
        static_configs = [{
          targets = [ "localhost:3100" ];
          labels = {
            instance = "hypervisor";
            role = "loki";
          };
        }];
        scrape_interval = "15s";
      }
      {
        job_name = "grafana";
        static_configs = [{
          targets = [ "localhost:3000" ];
          labels = {
            instance = "hypervisor";
            role = "grafana";
          };
        }];
        scrape_interval = "15s";
      }
    ];
  };

  # Open firewall for Prometheus
  networking.firewall.allowedTCPPorts = [ 9090 ];
}
