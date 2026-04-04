# hosts/hypervisor/twilio-webhook.nix
# Reverse proxy for inbound Twilio voice webhooks.
# Twilio sends call events (answered, DTMF, status callbacks) to this endpoint,
# which forwards them to the OpenClaw voice-call plugin inside the VM.
#
# Usage:
#   1. Point a DNS record (e.g., twilio.robw.fyi) to the hypervisor's public IP
#   2. Set the Twilio webhook URL to https://twilio.robw.fyi/voice/webhook
#   3. Configure the voice-call plugin's publicUrl to match
{ lib, ... }:

let
  # Which VM slot receives the webhooks (slot1 = 10.1.0.2)
  targetSlotIp = "10.1.0.2";
  targetPort = 3334;
  domain = "twilio.robw.fyi";
in
{
  services.nginx.virtualHosts.${domain} = {
    enableACME = true;
    forceSSL = true;

    # Twilio webhook endpoint — forwards to the VM's voice-call plugin
    locations."/voice/" = {
      extraConfig = ''
        proxy_pass http://${targetSlotIp}:${toString targetPort};
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_set_header X-Twilio-Signature $http_x_twilio_signature;

        # Twilio expects fast responses; increase timeouts for TTS generation
        proxy_read_timeout 30s;
        proxy_send_timeout 30s;
      '';
    };

    # Health check for monitoring
    locations."= /health" = {
      extraConfig = ''
        return 200 "ok";
        add_header Content-Type text/plain;
      '';
    };

    # Block everything else
    locations."/" = {
      extraConfig = ''
        return 404;
      '';
    };
  };
}
