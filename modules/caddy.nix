# modules/caddy.nix
# Caddy reverse proxy configuration for webhook service
# Provides TLS termination and public HTTPS endpoint
{ config, pkgs, lib, ... }:

with lib;

let
  cfg = config.services.microvm-caddy;

in {
  options.services.microvm-caddy = {
    enable = mkEnableOption "Caddy reverse proxy for webhook service";

    domain = mkOption {
      type = types.str;
      example = "webhooks.example.com";
      description = "Domain name for the webhook endpoint";
    };

    email = mkOption {
      type = types.str;
      example = "admin@example.com";
      description = "Email address for Let's Encrypt certificate notifications";
    };

    webhookPort = mkOption {
      type = types.port;
      default = 9000;
      description = "Local port where webhook service is running";
    };

    enableAccessLog = mkOption {
      type = types.bool;
      default = true;
      description = "Enable access logging for webhook requests";
    };

    extraConfig = mkOption {
      type = types.lines;
      default = "";
      description = "Extra Caddy configuration to append";
    };
  };

  config = mkIf cfg.enable {
    # Enable Caddy web server
    services.caddy = {
      enable = true;
      email = cfg.email;

      # Global options
      globalConfig = ''
        # Enable admin API on localhost only
        admin localhost:2019

        # Email for Let's Encrypt
        email ${cfg.email}

        # Use Let's Encrypt production by default
        # For testing, uncomment this to use staging:
        # acme_ca https://acme-staging-v02.api.letsencrypt.org/directory
      '';

      # Virtual host configuration
      virtualHosts."${cfg.domain}" = {
        extraConfig = ''
          # Enable access logging
          ${optionalString cfg.enableAccessLog ''
            log {
              output file /var/log/caddy/webhook-access.log {
                roll_size 10mb
                roll_keep 5
              }
              format json
            }
          ''}

          # Rate limiting to prevent abuse
          route {
            # Limit to 10 requests per minute per IP
            rate_limit {
              zone webhook {
                key {remote_host}
                events 10
                window 1m
              }
            }

            # Health check endpoint (no auth required)
            handle /hooks/health {
              reverse_proxy 127.0.0.1:${toString cfg.webhookPort}
            }

            # All other webhook endpoints
            handle /hooks/* {
              # Add security headers
              header {
                # Prevent clickjacking
                X-Frame-Options "DENY"
                # Prevent MIME sniffing
                X-Content-Type-Options "nosniff"
                # Enable browser XSS protection
                X-XSS-Protection "1; mode=block"
                # Remove server information
                -Server
              }

              # Proxy to webhook service
              reverse_proxy 127.0.0.1:${toString cfg.webhookPort} {
                # Health check
                health_uri /hooks/health
                health_interval 30s
                health_timeout 5s

                # Forward real IP
                header_up X-Real-IP {remote_host}
                header_up X-Forwarded-For {remote_host}
                header_up X-Forwarded-Proto {scheme}
              }
            }

            # Default: 404 for other paths
            handle {
              respond "Not Found" 404
            }
          }

          ${cfg.extraConfig}
        '';
      };
    };

    # Open firewall for HTTPS
    networking.firewall.allowedTCPPorts = [ 80 443 ];

    # Ensure log directory exists
    systemd.tmpfiles.rules = [
      "d /var/log/caddy 0755 caddy caddy -"
    ];

    # Add caddy package for management commands
    environment.systemPackages = with pkgs; [
      caddy
    ];
  };
}
