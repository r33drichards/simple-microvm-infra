# hosts/hypervisor/litellm.nix
# LiteLLM proxy — exposes OpenRouter models as OpenAI-compatible API on port 4000
#
# Accessible from slots at http://10.X.0.1:4000
# Credentials: /etc/litellm/env  (OPENROUTER_API_KEY=...)
{ pkgs, ... }:
{
  systemd.services.litellm = {
    description = "LiteLLM OpenAI-compatible proxy";
    after = [ "network.target" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      ExecStart = "${pkgs.litellm}/bin/litellm --config /etc/litellm/config.yaml --port 4000 --num_workers 1";
      EnvironmentFile = "/etc/litellm/env";
      Restart = "on-failure";
      RestartSec = "5s";
      DynamicUser = true;
    };
  };

  environment.etc."litellm/config.yaml".source = ./litellm-config.yaml;

  environment.etc."litellm/env.example".text = ''
    OPENROUTER_API_KEY=your_key_here
  '';
}
