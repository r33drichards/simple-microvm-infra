# hosts/hypervisor/otel-collector.nix
# Receives OTLP from slot-side otelcol collectors and fans out:
#   metrics -> Prometheus remote_write (port 9090)
#   logs    -> Loki HTTP push (port 3100)
# Listens on 0.0.0.0:4317. Reachability is governed by the nftables ruleset
# in hosts/hypervisor/network.nix (NixOS firewall module is disabled on this
# host): bridges (br-slot*), tailscale0, and lo can reach it; the internet
# (enP2p4s0) is dropped by default. That matches how Grafana/Prometheus/Loki
# are already exposed on this host.
{ config, pkgs, ... }:

{
  services.opentelemetry-collector = {
    enable = true;
    package = pkgs.opentelemetry-collector-contrib;
    settings = {
      receivers.otlp.protocols = {
        grpc.endpoint = "0.0.0.0:4317";
        # http intentionally omitted — slots only use gRPC
      };

      processors = {
        batch = {
          timeout = "10s";
          send_batch_size = 1024;
        };
        memory_limiter = {
          check_interval = "5s";
          limit_percentage = 75;
          spike_limit_percentage = 20;
        };
      };

      exporters = {
        prometheusremotewrite = {
          endpoint = "http://127.0.0.1:9090/api/v1/write";
          # Keep resource labels as Prom labels
          resource_to_telemetry_conversion.enabled = true;
        };
        loki = {
          endpoint = "http://127.0.0.1:3100/loki/api/v1/push";
          default_labels_enabled = {
            exporter = false;
            job      = true;
            instance = true;
            level    = true;
          };
        };
      };

      service.pipelines = {
        metrics = {
          receivers = [ "otlp" ];
          processors = [ "memory_limiter" "batch" ];
          exporters = [ "prometheusremotewrite" ];
        };
        logs = {
          receivers = [ "otlp" ];
          processors = [ "memory_limiter" "batch" ];
          exporters = [ "loki" ];
        };
      };
    };
  };

  # Prometheus must accept remote_write (disabled by default in NixOS module).
  services.prometheus.extraFlags = [
    "--web.enable-remote-write-receiver"
  ];

  # Ensure Prometheus and Loki are up before otelcol starts pushing, so the
  # cold-boot retry queue doesn't burn time waiting on endpoints that haven't
  # bound yet. `wants` (not `requires`) — otelcol keeps running if they restart.
  systemd.services.opentelemetry-collector = {
    after = [ "prometheus.service" "loki.service" ];
    wants = [ "prometheus.service" "loki.service" ];
  };
}
