# Per-slot OAuth proxy systemd services.
# Each slot gets its own proxy instance on port 4180+N.
#
# Credentials live in /etc/oauth-proxy/slotN.env (not in repo).
# See /etc/oauth-proxy/example.env for the required variables.
{ config, pkgs, lib, ... }:

let
  networks = import ../../modules/networks.nix;
  oauthProxy = pkgs.callPackage ./oauth-proxy {};

  mkService = slotName: _net:
    let
      n    = lib.toInt (networks.slotNumber slotName);
      port = 4180 + n;
    in
    lib.nameValuePair "oauth-proxy-${slotName}" {
      description = "OAuth proxy for ${slotName}";
      after       = [ "network.target" ];
      wantedBy    = [ "multi-user.target" ];
      serviceConfig = {
        ExecStart       = "${oauthProxy}/bin/oauth-proxy";
        EnvironmentFile = "/etc/oauth-proxy/${slotName}.env";
        Environment     = [
          "PORT=${toString port}"
          "SIGN_IN_BASE_URL=http://${config.networking.hostName}:${toString port}"
          "AUTHZ_POLICY_FILE=${oauthProxy}/share/oauth-proxy/policy.json"
        ];
        Restart         = "on-failure";
        RestartSec      = "5s";
        DynamicUser     = true;
      };
    };

in
{
  systemd.services = lib.mapAttrs' mkService networks.networks;

  environment.etc."oauth-proxy/example.env".text = ''
    OAUTH2_CLIENT_ID=your_github_client_id
    OAUTH2_CLIENT_SECRET=your_github_client_secret
    OAUTH2_AUTH_URL=https://github.com/login/oauth/authorize
    OAUTH2_TOKEN_URL=https://github.com/login/oauth/access_token
    OAUTH2_REDIRECT_URI=http://YOUR_HYPERVISOR_IP:PORT/auth/callback
    OAUTH2_UPSTREAM=https://api.github.com
    OAUTH2_SCOPE=read:user user:email
    OAUTH2_USERINFO_URL=https://api.github.com/user
  '';
}
