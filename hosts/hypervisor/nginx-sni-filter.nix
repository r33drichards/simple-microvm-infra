# hosts/hypervisor/nginx-sni-filter.nix
# SNI-based domain filtering for MicroVMs using nginx stream module.
#
# Reads the TLS ClientHello SNI field to determine the destination domain,
# then either proxies the connection through (allowed) or resets it (denied).
# No MITM, no certificate injection, no decryption — traffic passes through
# untouched. This preserves WebSockets, AWS SigV4 signatures, and streaming.
#
# HTTP (port 80) is proxied through nginx (unfiltered at L7).
{ config, pkgs, lib, ... }:

let
  networks = import ../../modules/networks.nix;
  bridges = lib.attrValues (lib.mapAttrs (_: net: net.bridge) networks.networks);
  bridgeList = lib.concatStringsSep ", " (map (b: "\"${b}\"") bridges);

  httpsPort = 3129;
  httpPort = 3128;

  # Allowed domains matched by SNI (TLS ClientHello) for HTTPS.
  # Leading dot = wildcard subdomains: ".example.com" matches *.example.com
  allowedDomains = [
    # === NPM Registry and Package Managers ===
    "registry.npmjs.org"
    "registry.npmjs.com"
    "npmjs.org"
    "npmjs.com"
    "nodejs.org"
    "nodesource.com"

    # === Yarn ===
    "yarnpkg.com"
    ".yarnpkg.com"

    # === GitHub ===
    "github.com"
    ".github.com"
    ".githubusercontent.com"
    "codeload.github.com"
    "ghcr.io"
    "packages.github.com"
    "npm.pkg.github.com"

    # === GitLab ===
    "gitlab.com"
    "registry.gitlab.com"

    # === Bitbucket ===
    "bitbucket.org"

    # === Python / PyPI ===
    "pypi.org"
    "files.pythonhosted.org"
    "pythonhosted.org"
    "bootstrap.pypa.io"
    "pypa.io"

    # === Ubuntu / Debian Package Repositories ===
    "archive.ubuntu.com"
    "security.ubuntu.com"
    "ports.ubuntu.com"
    "keyserver.ubuntu.com"
    "ubuntu.com"
    "deb.debian.org"
    "security.debian.org"
    ".deb.debian.org"
    "ftp.debian.org"
    "debian.org"

    # === Alpine ===
    ".alpinelinux.org"

    # === CDN / Content Delivery ===
    "fastly.com"
    ".fastly.net"
    "cloudflare.com"
    ".cloudflare.net"

    # === JavaScript CDNs ===
    "unpkg.com"
    ".jsdelivr.net"
    ".cdnjs.cloudflare.com"

    # === AI / ML Services ===
    "anthropic.com"
    ".anthropic.com"
    "cursor.com"
    ".cursor.com"
    "openai.com"
    ".openai.com"
    "perplexity.ai"
    ".perplexity.ai"
    "deepseek.com"
    ".deepseek.com"
    "groq.com"
    ".groq.com"
    "expo.dev"
    ".expo.dev"
    "openrouter.ai"

    # === Docker Registries ===
    "docker.com"
    ".docker.io"
    ".docker.com"
    "hub.docker.com"
    ".cloudflare.docker.com"

    # === Microsoft Container Registry ===
    "mcr.microsoft.com"
    ".microsoft.com"

    # === Kubernetes Registry ===
    "registry.k8s.io"
    ".k8s.io"

    # === Google Container Registry / GCP ===
    "gcr.io"
    ".gcr.io"
    "cloud.google.com"
    ".googleapis.com"
    ".gstatic.com"
    "storage.googleapis.com"

    # === Quay ===
    "quay.io"
    ".quay-registry.s3.amazonaws.com"

    # === AWS ===
    ".amazonaws.com"

    # === Maven / Apache ===
    ".maven.org"
    ".apache.org"

    # === Daytona Platform ===
    "daytona.io"
    ".daytona.io"

    # === NixOS / Nix ===
    "nixos.org"
    ".nixos.org"

    # === Rust / Cargo ===
    "crates.io"
    ".crates.io"
    "rust-lang.org"
    ".rust-lang.org"

    # === Go Modules ===
    "proxy.golang.org"
    "golang.org"
    "go.dev"
    "sum.golang.org"

    # === Tailscale ===
    "tailscale.com"
    ".tailscale.com"

    # === Slack ===
    "slack.com"
    ".slack.com"

    # === WhatsApp Web ===
    "web.whatsapp.com"
    "whatsapp.com"
    ".whatsapp.com"
    ".whatsapp.net"
    ".wa.me"

    # === Twilio ===
    "twilio.com"
    ".twilio.com"
    "twiliocdn.com"
    ".twiliocdn.com"

    # === OpenStreetMap ===
    "openstreetmap.org"
    ".openstreetmap.org"
  ];

  # Build nginx stream map entries: allowed → proxy to destination; denied → reject endpoint
  mapEntries = lib.concatMapStringsSep "\n    " (
    domain:
    if lib.hasPrefix "." domain then
      "~*\\${domain}$  $ssl_preread_server_name:443;"
    else
      "${domain}  ${domain}:443;"
  ) allowedDomains;
in
{
  services.nginx = {
    enable = true;

    streamConfig = ''
      # Resolve destinations via upstream DNS
      resolver 1.1.1.1 valid=30s ipv6=off;

      # Map SNI hostname to proxy target (allowed) or reject endpoint (denied)
      map $ssl_preread_server_name $sni_upstream {
        default  "127.0.0.1:${toString (httpsPort + 1)}";
        ${mapEntries}
      }

      log_format sni_log '$remote_addr [$time_local] SNI=$ssl_preread_server_name upstream=$sni_upstream status=$status';

      # HTTPS: SNI-based passthrough filter
      server {
        listen ${toString httpsPort};
        ssl_preread on;
        proxy_pass $sni_upstream;
        proxy_connect_timeout 5s;
        proxy_timeout 300s;
        access_log /var/log/nginx/sni-filter.log sni_log;
      }

      # Reject endpoint — denied HTTPS connections land here and get an empty response
      server {
        listen 127.0.0.1:${toString (httpsPort + 1)};
        return "";
      }
    '';

    # HTTP: proxy all traffic through (allowlist applies at HTTPS/SNI layer)
    virtualHosts."_http_filter" = {
      listen = [
        {
          addr = "127.0.0.1";
          port = httpPort;
        }
      ];
      default = true;
      locations."/" = {
        extraConfig = ''
          resolver 1.1.1.1 valid=30s ipv6=off;
          proxy_pass http://$host$request_uri;
          proxy_set_header Host $host;
        '';
      };
    };
  };

  # Redirect VM HTTP/HTTPS traffic through nginx instead of letting it go directly out
  networking.nftables.tables.nginx-filter = {
    family = "ip";
    content = ''
      chain prerouting {
        type nat hook prerouting priority dstnat - 1; policy accept;
        iifname { ${bridgeList} } tcp dport 443 dnat to 127.0.0.1:${toString httpsPort}
        iifname { ${bridgeList} } tcp dport 80 dnat to 127.0.0.1:${toString httpPort}
      }
    '';
  };
}
