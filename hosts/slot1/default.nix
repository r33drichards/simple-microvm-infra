# hosts/slot1/default.nix
# Slot1-specific config: Comin GitOps + XFCE desktop + Chromium
#
# Access via RDP through SSH tunnel:
#   ssh -i ~/.ssh/rw.pem -L 3389:10.1.0.2:3389 root@<hypervisor-ip>
#   then connect RDP client to localhost:3389
{ pkgs, lib, ... }:

{
  # GitOps: Comin polls this repo and applies nixosConfigurations.slot1
  services.comin = {
    enable = true;
    remotes = [{
      name = "origin";
      url = "https://github.com/r33drichards/simple-microvm-infra.git";
      branches.main.name = "main";
    }];
  };

  # XFCE desktop
  services.xserver = {
    enable = true;
    desktopManager.xfce.enable = true;
    displayManager.lightdm.enable = true;
  };

  # Remote desktop access (RDP)
  services.xrdp = {
    enable = true;
    defaultWindowManager = "xfce4-session";
    openFirewall = false;
  };

  environment.systemPackages = with pkgs; [
    chromium
    git
  ];
}
