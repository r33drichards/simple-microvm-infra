# hosts/hypervisor/tailscale.nix
# Tailscale configuration for hypervisor
# Enables: VPN access, subnet routing, Grafana serving
{ config, pkgs, ... }:

{
  # Enable Tailscale
  services.tailscale.enable = true;

  # Configure Tailscale to serve Grafana on the tailnet
  # This makes Grafana accessible at https://<hostname>.tailXXXXX.ts.net
  systemd.services.tailscale-serve-grafana = {
    description = "Expose Grafana via Tailscale Serve";
    after = [ "tailscaled.service" "grafana.service" ];
    wants = [ "tailscaled.service" "grafana.service" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script = ''
      # Wait for Tailscale to be ready
      until ${pkgs.tailscale}/bin/tailscale status &>/dev/null; do
        echo "Waiting for Tailscale to be ready..."
        sleep 2
      done

      # Serve Grafana on HTTPS via Tailscale
      # This exposes Grafana at https://<hostname>.tailXXXXX.ts.net
      echo "Configuring Tailscale to serve Grafana..."
      ${pkgs.tailscale}/bin/tailscale serve https / http://localhost:3000

      echo "Grafana is now accessible via Tailscale HTTPS!"
      echo "Access it at: https://$(${pkgs.tailscale}/bin/tailscale status --json | ${pkgs.jq}/bin/jq -r '.Self.DNSName' | sed 's/\.$//')"
    '';
  };

  # Post-deploy hook to display Grafana URL
  systemd.services.grafana.postStart = ''
    sleep 5
    if ${pkgs.systemd}/bin/systemctl is-active tailscaled.service &>/dev/null; then
      TAILSCALE_URL=$(${pkgs.tailscale}/bin/tailscale status --json 2>/dev/null | ${pkgs.jq}/bin/jq -r '.Self.DNSName' 2>/dev/null | sed 's/\.$//' || echo "unknown")
      if [ "$TAILSCALE_URL" != "unknown" ]; then
        echo "========================================" >&2
        echo "Grafana is available at:" >&2
        echo "  https://$TAILSCALE_URL" >&2
        echo "  http://localhost:3000 (local)" >&2
        echo "Default credentials: admin/admin" >&2
        echo "========================================" >&2
      fi
    fi
  '';
}
