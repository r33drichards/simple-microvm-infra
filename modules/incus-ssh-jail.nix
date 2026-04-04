# modules/incus-ssh-jail.nix
#
# Incus SSH jail adapted for running inside a microVM.
#
# Uses dir storage (no dedicated block device needed — stores on the VM's
# root ext4 filesystem). Per-user confined projects with daemon-enforced
# scriptlet authorization, project restrictions, resource limits, bwrapped
# incus CLI, and SSH ForceCommand + no forwarding.
#
# Requires nix-bwrapper NixOS module to be loaded (provides pkgs.mkBwrapper).
#
# Usage in a slot definition (flake.nix):
#
#   slot6 = {
#     config = { microvm.mem = 8192; microvm.vcpu = 4; };
#     extraModules = [
#       nix-bwrapper.nixosModules.default
#       {
#         services.incus-ssh-jail = {
#           enable = true;
#           users.alice = {
#             authorizedKeys = [ "ssh-ed25519 AAAA..." ];
#             limits.memory = "4GiB";
#           };
#         };
#       }
#     ];
#   };

{ config, lib, pkgs, ... }:

let
  cfg = config.services.incus-ssh-jail;

  # ---------------------------------------------------------------------------
  # Scriptlet authorization — runs inside incusd, enforced on every API call.
  # Jailed users are in `incus` group so the daemon scopes them to their own
  # project. The scriptlet further restricts which operations they may perform.
  # ---------------------------------------------------------------------------
  scriptletText =
    let
      userList = "[" + lib.concatStringsSep ", "
        (map (u: ''"${u}"'') (builtins.attrNames cfg.users))
        + "]";
    in ''
      # Jailed Unix socket users — populated from NixOS config at eval time.
      JAILED_USERS = ${userList}

      # Permitted entitlements per resource type.
      ALLOWED = {
          "instance": [
              "can_view",
              "can_update_state",
              "can_exec",
              "can_access_console",
              "can_access_files",
              "can_connect_sftp",
              "can_manage_snapshots",
          ],
          "project": [
              "can_view",
              "can_view_operations",
              "can_view_events",
              "can_create_instances",
              "can_create_storage_volumes",
              "can_create_images",
              "can_create_image_aliases",
              "can_create_profiles",
          ],
          "image":          ["can_view"],
          "image_alias":    ["can_view"],
          "profile":        ["can_view"],
          "network":        ["can_view"],
          "network_acl":    ["can_view"],
          "storage_pool":   ["can_view"],
          "storage_volume": [
              "can_view",
              "can_access_files",
              "can_connect_sftp",
              "can_manage_snapshots",
              "can_manage_backups",
          ],
      }

      def authorize(details, object, entitlement):
          if details.Protocol != "unix":
              return True

          if details.Username not in JAILED_USERS:
              return True

          if object == "server":
              return entitlement in ["can_view", "can_view_resources",
                                     "can_view_metrics", "authenticated"]

          return entitlement in ALLOWED.get(object, [])
    '';

  # ---------------------------------------------------------------------------
  # bwrapped incus CLI — filesystem isolation via bubblewrap.
  # The scriptlet handles authorization; bwrap handles filesystem isolation.
  # ---------------------------------------------------------------------------
  bwrappedIncus = pkgs.mkBwrapper {
    app = {
      package   = pkgs.incus;
      runScript = "incus";
      bwrapPath = "incus-jail";
    };

    fhsenv.unshareNet = true;
    fhsenv.unshareIpc = true;

    sockets = {
      x11      = false;
      wayland  = false;
      pipewire = false;
      pulse    = false;
    };

    mounts = {
      read      = lib.mkForce [ ];
      readWrite = lib.mkForce [
        "$HOME/.config/incus"
      ];
    };

    fhsenv.extraBwrapArgs = [
      "--bind" "/var/lib/incus/unix.socket" "/var/lib/incus/unix.socket"
    ];
  };

  # ---------------------------------------------------------------------------
  # Per-user project restriction service
  # ---------------------------------------------------------------------------
  mkProjectSetupService = username: userCfg:
    let
      project = username;
      lim     = userCfg.limits;
      net     = cfg.network.name;
      pool    = cfg.storagePool.name;
    in {
      description     = "Configure incus project restrictions for ${username}";
      after           = [ "incus.service" ];
      requires        = [ "incus.service" ];
      wantedBy        = [ "multi-user.target" ];
      path            = [ pkgs.incus pkgs.jq ];
      serviceConfig   = {
        Type            = "oneshot";
        RemainAfterExit = true;
        Restart         = "on-failure";
        RestartSec      = "5s";
      };
      script = ''
        set -euo pipefail

        # Wait for socket
        until [ -S /var/lib/incus/unix.socket ]; do sleep 2; done

        if ! incus project list --format=json \
            | jq -e --arg p "${project}" '.[] | select(.name == $p)' >/dev/null 2>&1
        then
          echo "Creating project ${project}..."
          incus project create "${project}"
        fi

        echo "Applying restrictions to project ${project}..."

        incus project set "${project}" restricted=true

        # Container security
        incus project set "${project}" restricted.containers.privilege=unprivileged
        incus project set "${project}" restricted.containers.nesting=block
        incus project set "${project}" restricted.containers.lowlevel=block

        # VM security
        incus project set "${project}" restricted.virtual-machines.lowlevel=block

        # Device restrictions
        incus project set "${project}" restricted.devices.disk=managed
        incus project set "${project}" restricted.devices.disk.paths=
        incus project set "${project}" restricted.devices.gpu=block
        incus project set "${project}" restricted.devices.infiniband=block
        incus project set "${project}" restricted.devices.unix-block=block
        incus project set "${project}" restricted.devices.unix-char=block
        incus project set "${project}" restricted.devices.unix-hotplug=block
        incus project set "${project}" restricted.devices.usb=block
        incus project set "${project}" restricted.devices.pci=block
        incus project set "${project}" restricted.devices.nic=managed
        incus project set "${project}" restricted.networks.access="${net}"

        # Snapshots
        incus project set "${project}" restricted.snapshots.schedule=block

        # Resource limits
        ${lib.optionalString (lim.containers != null)
          ''incus project set "${project}" limits.containers=${toString lim.containers}''}
        ${lib.optionalString (lim.cpu != null)
          ''incus project set "${project}" limits.cpu=${toString lim.cpu}''}
        ${lib.optionalString (lim.memory != null)
          ''incus project set "${project}" limits.memory=${lim.memory}''}
        ${lib.optionalString (lim.disk != null)
          ''incus project set "${project}" limits.disk=${lim.disk}''}
        ${lib.optionalString (lim.processes != null)
          ''incus project set "${project}" limits.processes=${toString lim.processes}''}
        ${lib.optionalString (lim.networks != null)
          ''incus project set "${project}" limits.networks=${toString lim.networks}''}

        echo "Project ${project} configured."
      '';
    };

  # ---------------------------------------------------------------------------
  # Option types
  # ---------------------------------------------------------------------------
  limitsSubmodule = lib.types.submodule {
    options = {
      containers = lib.mkOption {
        type    = lib.types.nullOr lib.types.ints.positive;
        default = 5;
        description = "Max containers. null = unlimited.";
      };
      cpu = lib.mkOption {
        type    = lib.types.nullOr lib.types.ints.positive;
        default = 4;
        description = "Max total vCPUs across all instances.";
      };
      memory = lib.mkOption {
        type    = lib.types.nullOr lib.types.str;
        default = "8GiB";
        description = "Max total memory across all instances.";
      };
      disk = lib.mkOption {
        type    = lib.types.nullOr lib.types.str;
        default = "50GiB";
        description = "Max total disk across all instances.";
      };
      processes = lib.mkOption {
        type    = lib.types.nullOr lib.types.ints.positive;
        default = 10000;
        description = "Max total processes across all instances.";
      };
      networks = lib.mkOption {
        type    = lib.types.nullOr lib.types.ints.positive;
        default = null;
        description = "Max networks the project may create. null = unlimited.";
      };
    };
  };

  userSubmodule = { name, ... }: {
    options = {
      authorizedKeys = lib.mkOption {
        type    = lib.types.listOf lib.types.str;
        default = [ ];
        description = "SSH public keys for this user.";
      };
      uid = lib.mkOption {
        type    = lib.types.nullOr lib.types.int;
        default = null;
        description = "Optional fixed UID for reproducible deployments.";
      };
      limits = lib.mkOption {
        type    = limitsSubmodule;
        default = { };
        description = "Resource limits applied to this user's incus project.";
      };
    };
  };

in
{
  # ---------------------------------------------------------------------------
  # Module options
  # ---------------------------------------------------------------------------
  options.services.incus-ssh-jail = {
    enable = lib.mkEnableOption "incus SSH jail with per-user restricted projects";

    storagePool = {
      name = lib.mkOption {
        type    = lib.types.str;
        default = "default";
        description = "Name of the incus storage pool.";
      };
      path = lib.mkOption {
        type    = lib.types.str;
        default = "/var/lib/incus/storage";
        description = "Directory path for the dir storage pool.";
      };
      rootDiskSize = lib.mkOption {
        type    = lib.types.str;
        default = "20GiB";
        description = "Default root disk size for the default profile.";
      };
    };

    network = {
      name = lib.mkOption {
        type    = lib.types.str;
        default = "incusbr0";
        description = "Name of the managed bridge network.";
      };
      ipv4Cidr = lib.mkOption {
        type    = lib.types.str;
        default = "10.0.100.1/24";
        description = "IPv4 address and prefix for the bridge (gateway address).";
      };
      ipv4Nat = lib.mkOption {
        type    = lib.types.bool;
        default = true;
        description = "Enable IPv4 NAT for containers.";
      };
    };

    users = lib.mkOption {
      type    = lib.types.attrsOf (lib.types.submodule userSubmodule);
      default = { };
      description = "Jailed users, keyed by username.";
      example = lib.literalExpression ''
        {
          alice = {
            authorizedKeys = [ "ssh-ed25519 AAAA..." ];
            limits = { containers = 3; memory = "4GiB"; disk = "20GiB"; };
          };
        }
      '';
    };
  };

  # ---------------------------------------------------------------------------
  # Implementation
  # ---------------------------------------------------------------------------
  config = lib.mkIf cfg.enable {

    assertions = [
      {
        assertion = cfg.users != { };
        message   = "services.incus-ssh-jail.users must not be empty";
      }
      {
        assertion = config.services.openssh.enable;
        message   = "services.incus-ssh-jail requires services.openssh.enable = true";
      }
    ];

    # nftables required by incus for container networking
    networking.nftables.enable = true;

    # ---------------------------------------------------------------------------
    # Incus daemon with dir storage (no dedicated block device needed)
    # ---------------------------------------------------------------------------
    virtualisation.incus = {
      enable = true;

      preseed = {
        config = {
          "authorization.scriptlet" = scriptletText;
        };

        storage_pools = [
          {
            name   = cfg.storagePool.name;
            driver = "dir";
            config = {
              source = cfg.storagePool.path;
            };
          }
        ];

        networks = [
          {
            name   = cfg.network.name;
            type   = "bridge";
            config = {
              "ipv4.address" = cfg.network.ipv4Cidr;
              "ipv4.nat"     = lib.boolToString cfg.network.ipv4Nat;
              "ipv6.address" = "none";
            };
          }
        ];

        profiles = [
          {
            name    = "default";
            devices = {
              root = {
                path = "/";
                pool = cfg.storagePool.name;
                size = cfg.storagePool.rootDiskSize;
                type = "disk";
              };
              eth0 = {
                name    = "eth0";
                network = cfg.network.name;
                type    = "nic";
              };
            };
          }
        ];
      };
    };

    # Storage directory
    systemd.tmpfiles.rules = [
      "d ${cfg.storagePool.path} 0755 root root -"
    ];

    # ---------------------------------------------------------------------------
    # Jailed users — incus group only (never incus-admin)
    # ---------------------------------------------------------------------------
    users.users = lib.mapAttrs (username: userCfg: {
      isNormalUser = true;
      home         = "/home/${username}";
      createHome   = true;
      shell        = "${pkgs.shadow}/bin/nologin";
      extraGroups  = [ "incus" ];
      uid          = lib.mkIf (userCfg.uid != null) userCfg.uid;
      openssh.authorizedKeys.keys = userCfg.authorizedKeys;
    }) cfg.users;

    # ---------------------------------------------------------------------------
    # bwrapped incus CLI
    # ---------------------------------------------------------------------------
    environment.systemPackages = [ bwrappedIncus ];

    # ---------------------------------------------------------------------------
    # Systemd: per-user project restriction services
    # ---------------------------------------------------------------------------
    systemd.services = lib.mapAttrs' (username: userCfg:
      lib.nameValuePair
        "incus-jail-project-${username}"
        (mkProjectSetupService username userCfg)
    ) cfg.users;

    # Ensure sshd starts after incus so the socket exists for bwrap binding
    systemd.services.sshd = {
      after = [ "incus.service" ];
      wants = [ "incus.service" ];
    };

    # ---------------------------------------------------------------------------
    # SSH: ForceCommand per jailed user
    # ---------------------------------------------------------------------------
    services.openssh.extraConfig = lib.concatStrings (
      lib.mapAttrsToList (username: _: ''
        Match User ${username}
          ForceCommand ${lib.getExe bwrappedIncus}
          AllowTcpForwarding no
          AllowAgentForwarding no
          X11Forwarding no
          PermitTunnel no
      '') cfg.users
    );
  };
}
