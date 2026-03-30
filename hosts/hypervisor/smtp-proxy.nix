# hosts/hypervisor/smtp-proxy.nix
# SMTP blocking + SES relay proxy for MicroVMs.
#
# 1. Blocks direct SMTP (ports 25, 465, 587) from VMs to the internet
# 2. DNATs port 587 from VMs to a local SMTP-to-SES relay proxy
# 3. The proxy accepts plaintext SMTP and forwards via AWS SES API
#
# VMs can send mail by connecting to any host on port 587 — nftables
# transparently redirects to the local proxy. No VM-side config needed.
{ config, pkgs, lib, ... }:

let
  networks = import ../../modules/networks.nix;
  bridges = lib.attrValues (lib.mapAttrs (_: net: net.bridge) networks.networks);
  bridgeList = lib.concatStringsSep ", " (map (b: "\"${b}\"") bridges);

  # Listen addresses: all bridge gateway IPs
  listenAddrs = lib.concatStringsSep ","
    (lib.mapAttrsToList (_: net: "${net.subnet}.1") networks.networks);

  smtpProxyPort = 2525;

  smtpProxy = import ./smtp-proxy { inherit pkgs; };
in
{
  # --- SMTP-to-SES relay proxy service ---
  systemd.services.smtp-ses-proxy = {
    description = "SMTP-to-SES relay proxy for MicroVMs";
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    wantedBy = [ "multi-user.target" ];

    serviceConfig = {
      ExecStart = "${smtpProxy}/bin/smtp-ses-proxy";
      EnvironmentFile = "/etc/smtp-proxy/ses.env";
      Restart = "always";
      RestartSec = 5;

      # Hardening
      DynamicUser = true;
      NoNewPrivileges = true;
      ProtectSystem = "strict";
      ProtectHome = true;
      PrivateTmp = true;
      ProtectKernelTunables = true;
      ProtectKernelModules = true;
      ProtectControlGroups = true;
      RestrictAddressFamilies = [ "AF_INET" "AF_INET6" ];
      RestrictNamespaces = true;
      LockPersonality = true;
      MemoryDenyWriteExecute = true;
      RestrictRealtime = true;

      # Allow binding to privileged-ish port range
      AmbientCapabilities = [ "CAP_NET_BIND_SERVICE" ];
    };

    environment = {
      SMTP_LISTEN_PORT = toString smtpProxyPort;
      SMTP_LISTEN_ADDRS = "0.0.0.0";
    };
  };

  # --- nftables: redirect SMTP to local SES proxy ---
  # Note: direct VM→internet is already blocked by the default-deny forward
  # chain in network.nix. These DNAT rules intercept SMTP in prerouting
  # so VMs can send mail transparently through the SES proxy.
  networking.nftables.tables.smtp-filter = {
    family = "ip";
    content = ''
      chain smtp_redirect {
        type nat hook prerouting priority dstnat - 2; policy accept;

        # Redirect all SMTP ports from VMs to local SES proxy
        iifname { ${bridgeList} } tcp dport { 25, 465, 587 } dnat to 127.0.0.1:${toString smtpProxyPort}
      }
    '';
  };
}
