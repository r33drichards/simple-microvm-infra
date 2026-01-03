# hosts/hypervisor/dns-allowlist.nix
# DNS-based allowlist filtering for MicroVMs
# Uses CoreDNS with default-deny policy
{ config, pkgs, lib, ... }:

let
  # Upstream DNS servers for allowed domains
  upstreamDNS = "1.1.1.1 8.8.8.8";

  # Allowed domains - organized by category
  # CoreDNS will automatically handle subdomains (e.g., github.com covers *.github.com)
  allowedDomains = [
    # === NPM Registry and Package Managers ===
    "registry.npmjs.org"
    "registry.npmjs.com"
    "npmjs.org"
    "npmjs.com"
    "nodejs.org"
    "nodesource.com"
    "npm.pkg.github.com"

    # === Yarn Packages ===
    "yarnpkg.com"
    "classic.yarnpkg.com"
    "registry.yarnpkg.com"
    "repo.yarnpkg.com"
    "releases.yarnpkg.com"
    "yarn.npmjs.org"
    "yarnpkg.netlify.com"
    "dl.yarnpkg.com"

    # === GitHub ===
    "github.com"
    "api.github.com"
    "githubusercontent.com"
    "raw.githubusercontent.com"
    "github-releases.githubusercontent.com"
    "codeload.github.com"
    "ghcr.io"
    "packages.github.com"
    "objects.githubusercontent.com"

    # === GitLab ===
    "gitlab.com"
    "registry.gitlab.com"

    # === Bitbucket ===
    "bitbucket.org"

    # === Python Package Managers (PyPI) ===
    "pypi.org"
    "pypi.python.org"
    "files.pythonhosted.org"
    "pythonhosted.org"
    "bootstrap.pypa.io"
    "pypa.io"

    # === Ubuntu/Debian Package Repositories ===
    "archive.ubuntu.com"
    "security.ubuntu.com"
    "ubuntu.com"
    "deb.debian.org"
    "security.debian.org"
    "cdn-fastly.deb.debian.org"
    "ftp.debian.org"
    "debian.org"

    # === CDN and Content Delivery ===
    "fastly.com"
    "fastly.net"
    "cloudflare.com"
    "cloudflare.net"
    "cloudflareinsights.com"

    # === JavaScript CDNs ===
    "unpkg.com"
    "jsdelivr.net"
    "cdnjs.cloudflare.com"

    # === AI/ML Services ===
    "anthropic.com"
    "api.anthropic.com"
    "openai.com"
    "api.openai.com"
    "perplexity.ai"
    "api.perplexity.ai"
    "deepseek.com"
    "api.deepseek.com"
    "groq.com"
    "api.groq.com"
    "expo.dev"
    "api.expo.dev"
    "openrouter.ai"

    # === Docker Registries and Container Services ===
    "docker.com"
    "docker.io"
    "download.docker.com"
    "registry-1.docker.io"
    "registry.docker.io"
    "auth.docker.io"
    "index.docker.io"
    "hub.docker.com"
    "production.cloudflare.docker.com"

    # === Microsoft Container Registry ===
    "mcr.microsoft.com"
    "microsoft.com"

    # === Kubernetes Registry ===
    "registry.k8s.io"
    "k8s.io"

    # === Google Container Registry ===
    "gcr.io"
    "asia.gcr.io"
    "eu.gcr.io"
    "us.gcr.io"
    "marketplace.gcr.io"
    "registry.cloud.google.com"
    "cloud.google.com"
    "storage.googleapis.com"
    "googleapis.com"

    # === Quay ===
    "quay.io"
    "quay-registry.s3.amazonaws.com"

    # === Maven Repositories ===
    "maven.org"
    "repo1.maven.org"
    "repo.maven.apache.org"
    "apache.org"

    # === Google Fonts ===
    "fonts.googleapis.com"
    "fonts.gstatic.com"
    "gstatic.com"

    # === AWS S3 Endpoints ===
    "amazonaws.com"
    "s3.amazonaws.com"
    "s3.us-east-1.amazonaws.com"
    "s3.us-east-2.amazonaws.com"
    "s3.us-west-1.amazonaws.com"
    "s3.us-west-2.amazonaws.com"
    "s3.eu-central-1.amazonaws.com"
    "s3.eu-west-1.amazonaws.com"
    "s3.eu-west-2.amazonaws.com"

    # === Daytona Platform ===
    "daytona.io"
    "app.daytona.io"

    # === NixOS/Nix Package Manager ===
    "nixos.org"
    "cache.nixos.org"
    "channels.nixos.org"
    "releases.nixos.org"

    # === Rust/Cargo ===
    "crates.io"
    "static.crates.io"
    "rust-lang.org"
    "static.rust-lang.org"

    # === Go Modules ===
    "proxy.golang.org"
    "golang.org"
    "go.dev"
    "sum.golang.org"

    # === Tailscale (for VPN connectivity) ===
    "tailscale.com"
    "controlplane.tailscale.com"
    "login.tailscale.com"
  ];

  # MicroVM gateway IPs that CoreDNS should bind to
  # These are the gateway addresses for each VM's bridge network
  bindAddresses = [
    "10.1.0.1"  # br-vm1
    "10.2.0.1"  # br-vm2
    "10.3.0.1"  # br-vm3
    "10.4.0.1"  # br-vm4
    "10.5.0.1"  # br-vm5
  ];

  bindDirective = "bind ${lib.concatStringsSep " " bindAddresses}";

  # Generate CoreDNS config with forward blocks for each allowed domain
  # and a catch-all block that returns NXDOMAIN
  generateCorefile = domains: let
    # Create a forward block for each domain
    forwardBlocks = lib.concatMapStringsSep "\n" (domain: ''
      ${domain}:53 {
        ${bindDirective}
        forward . ${upstreamDNS}
        cache 300
        log
      }
    '') domains;
  in ''
    # Allowed domains - forward to upstream DNS
    ${forwardBlocks}

    # Catch-all: block everything else with NXDOMAIN
    .:53 {
      ${bindDirective}
      template ANY ANY {
        rcode NXDOMAIN
      }
      log . {
        class denial
      }
    }
  '';

in {
  # CoreDNS configuration
  services.coredns = {
    enable = true;
    config = generateCorefile allowedDomains;
  };

  # Open DNS port for VMs (port 53)
  # This is handled by nftables in network.nix, but we ensure the service binds correctly
  systemd.services.coredns = {
    serviceConfig = {
      # Ensure CoreDNS can bind to privileged port 53
      AmbientCapabilities = [ "CAP_NET_BIND_SERVICE" ];
    };
  };
}
