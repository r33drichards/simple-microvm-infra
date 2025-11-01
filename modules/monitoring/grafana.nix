# modules/monitoring/grafana.nix
# Grafana configuration for hypervisor
{ config, lib, pkgs, ... }:

{
  services.grafana = {
    enable = true;

    settings = {
      server = {
        http_addr = "0.0.0.0";
        http_port = 3000;
        domain = "localhost";
        root_url = "http://localhost:3000";
      };

      # Anonymous access for easy setup
      # CHANGE THIS in production!
      "auth.anonymous" = {
        enabled = true;
        org_role = "Admin";
      };

      security = {
        admin_user = "admin";
        admin_password = "admin";  # CHANGE THIS in production!
      };
    };

    provision = {
      enable = true;

      # Provision Prometheus datasource
      datasources.settings.datasources = [
        {
          name = "Prometheus";
          type = "prometheus";
          access = "proxy";
          url = "http://localhost:9090";
          isDefault = true;
          jsonData = {
            timeInterval = "15s";
          };
        }
        {
          name = "Loki";
          type = "loki";
          access = "proxy";
          url = "http://localhost:3100";
        }
      ];

      # Provision default dashboards
      dashboards.settings.providers = [
        {
          name = "default";
          options.path = "/var/lib/grafana/dashboards";
          disableDeletion = false;
          editable = true;
        }
      ];
    };
  };

  # Open firewall for Grafana
  networking.firewall.allowedTCPPorts = [ 3000 ];

  # Create dashboards directory
  systemd.tmpfiles.rules = [
    "d /var/lib/grafana/dashboards 0755 grafana grafana -"
  ];

  # Install pre-built dashboard for node-exporter
  environment.etc."grafana-dashboards/node-exporter.json" = {
    source = pkgs.fetchurl {
      url = "https://grafana.com/api/dashboards/1860/revisions/37/download";
      sha256 = "sha256-OWXthndRGP/P6XfNhD1p3ql1fLfnPQjAp5PCKtJSJ+8=";
    };
  };

  # Copy dashboard to Grafana on service start
  systemd.services.grafana.preStart = ''
    mkdir -p /var/lib/grafana/dashboards
    cp /etc/grafana-dashboards/node-exporter.json /var/lib/grafana/dashboards/ || true
    chown -R grafana:grafana /var/lib/grafana/dashboards
  '';
}
