{ ... }:
{
  imports = [ ./default.nix ];

  services.ebsVolumes = {
    enable = true;
    volumes."my-data" = {
      mountPoint = "/var/lib/data";
      sizeGiB = 50;
      poolName = "tank";
      dataset = "data";
      volumeType = "gp3";
      throughput = 125; # optional for gp3
      iops = 3000;      # optional for gp3
      encrypted = false;
      mountOptions = [ "nofail" "defaults" ];
    };
  };
}
