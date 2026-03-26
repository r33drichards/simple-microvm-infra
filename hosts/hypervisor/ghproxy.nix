# hosts/hypervisor/ghproxy.nix
# HTTPS reverse proxy for the GitHub OAuth proxy on o.robw.fyi.
# Routes /oauth2/callback → /auth/callback on localhost:4181 (oauth-proxy-slot1).
{ ... }:
{
  security.acme = {
    acceptTerms = true;
    defaults.email = "rwendt1337@gmail.com";
  };

  services.nginx.virtualHosts."o.robw.fyi" = {
    enableACME = true;
    forceSSL = true;
    locations."= /oauth2/callback" = {
      extraConfig = ''
        proxy_pass http://127.0.0.1:4181/auth/callback$is_args$args;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
      '';
    };
    locations."/" = {
      extraConfig = ''
        proxy_pass http://127.0.0.1:4181;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
      '';
    };
  };
}
