# modules/incus-ssh-jail/default.nix
#
# Complete incus SSH jail with:
#   - btrfs storage pool
#   - per-user confined projects (daemon-enforced via `incus` group)
#   - scriptlet authorization (daemon-enforced operation allowlist)
#   - project restrictions (no privileged containers, no host mounts, etc.)
#   - per-user resource limits
#   - bwrapped incus CLI (filesystem isolation)
#   - SSH ForceCommand + no forwarding
#
# Flake usage:
#
#   inputs.nix-bwrapper.url = "github:Naxdy/nix-bwrapper";
#
#   nixosConfigurations.myhost = nixpkgs.lib.nixosSystem {
#     modules = [
#       nix-bwrapper.nixosModules.default
#       ./modules/incus-ssh-jail
#       {
#         services.incus-ssh-jail = {
#           enable = true;
#           storagePool.device = "/dev/sdb";
#           users = {
#             alice = {
#               authorizedKeys = [ "ssh-ed25519 AAAA..." ];
#               limits.memory  = "8GiB";
#               limits.disk    = "50GiB";
#             };
#           };
#         };
#       }
#     ];
#   };

{ config, lib, pkgs, ... }:

let
  cfg = config.services.incus-ssh-jail;

  incusBin = lib.getExe pkgs.incus;

  # Scriptlet authorization — see scriptlet.nix for details.
  scriptletText = import ./scriptlet.nix {
    inherit lib;
    users = cfg.users;
  };

  # ---------------------------------------------------------------------------
  # bwrapped incus CLI — no wrapper script, no argument parsing.
  # The scriptlet handles authorization; bwrap handles filesystem isolation.
  # The sandbox can reach the incus socket and the user's config dir only.
  # ---------------------------------------------------------------------------
  bwrappedIncus = pkgs.mkBwrapper {
    app = {
      package   = pkgs.incus;
      runScript = "incus";
      bwrapPath = "incus-jail";
    };

    # No network — CLI speaks to daemon over the Unix socket only.
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
        # Persistent incus client config (local remote entry, client certs).
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
      after           = [ "incus.service" "incus-jail-init.service" ];
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

        # Pre-create the project. The `incus` group daemon names auto-created
        # projects after the OS username. Pre-creating here ensures restrictions
        # are in place before any user command ever runs.
        if ! incus project list --format=json \
            | jq -e --arg p "${project}" '.[] | select(.name == $p)' >/dev/null 2>&1
        then
          echo "Creating project ${project}..."
          incus project create "${project}"
        fi

        echo "Applying restrictions to project ${project}..."

        # Core — must be true for all restricted.* settings to take effect.
        incus project set "${project}" restricted=true

        # Container security
        # unprivileged: blocks security.privileged=true (no uid-0-mapped containers)
        incus project set "${project}" restricted.containers.privilege=unprivileged
        incus project set "${project}" restricted.containers.nesting=block
        incus project set "${project}" restricted.containers.lowlevel=block

        # VM security
        incus project set "${project}" restricted.virtual-machines.lowlevel=block

        # Device restrictions
        # managed: disk devices only if backed by a named storage pool (no host paths)
        incus project set "${project}" restricted.devices.disk=managed
        incus project set "${project}" restricted.devices.disk.paths=
        incus project set "${project}" restricted.devices.gpu=block
        incus project set "${project}" restricted.devices.infiniband=block
        incus project set "${project}" restricted.devices.unix-block=block
        incus project set "${project}" restricted.devices.unix-char=block
        incus project set "${project}" restricted.devices.unix-hotplug=block
        incus project set "${project}" restricted.devices.usb=block
        incus project set "${project}" restricted.devices.pci=block
        # managed: NICs only on named managed networks (no macvlan / sr-iov / physical)
        incus project set "${project}" restricted.devices.nic=managed
        # Restrict to the single managed bridge we control
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
        description = "Max total memory across all instances (e.g. '8GiB').";
      };
      disk = lib.mkOption {
        type    = lib.types.nullOr lib.types.str;
        default = "50GiB";
        description = "Max total disk across all instances (e.g. '50GiB').";
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
    enable = lib.mkEnableOption "incus SSH jail with btrfs storage and per-user restricted projects";

    storagePool = {
      name = lib.mkOption {
        type    = lib.types.str;
        default = "default";
        description = "Name of the incus storage pool.";
      };
      device = lib.mkOption {
        type    = lib.types.str;
        example = "/dev/sdb";
        description = ''
          Block device for the btrfs storage pool (e.g. /dev/sdb).
          Incus will format this device as btrfs on first init.
          WARNING: all existing data on the device will be destroyed.
          For a btrfs subvolume on an existing filesystem, provide the
          subvolume path (e.g. /mnt/data/incus).
        '';
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
          bob = {
            authorizedKeys = [ "ssh-ed25519 BBBB..." ];
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
        assertion = cfg.storagePool.device != "";
        message   = "services.incus-ssh-jail.storagePool.device must be set";
      }
      {
        assertion = cfg.users != { };
        message   = "services.incus-ssh-jail.users must not be empty";
      }
      {
        assertion = config.services.openssh.enable;
        message   = "services.incus-ssh-jail requires services.openssh.enable = true";
      }
    ];

    # nftables is required by incus on NixOS — iptables breaks container networking
    networking.nftables.enable = true;

    # ---------------------------------------------------------------------------
    # Incus daemon
    # ---------------------------------------------------------------------------
    virtualisation.incus = {
      enable = true;

      # Declarative initialization via preseed.
      # Re-applied on every rebuild — creates missing resources, updates existing
      # ones, never removes. Safe to run repeatedly.
      preseed = {
        # Scriptlet authorization — enforced by the daemon on every API call.
        # Dot in key name requires quoting in Nix attrset syntax.
        config = {
          "authorization.scriptlet" = scriptletText;
        };

        storage_pools = [
          {
            name   = cfg.storagePool.name;
            driver = "btrfs";
            config = {
              source = cfg.storagePool.device;
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

        # Default profile: attach to our bridge and btrfs pool.
        # Project resource limits will further cap per-user disk use.
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

    # ---------------------------------------------------------------------------
    # Jailed users — incus group only, never incus-admin.
    # The incusd daemon enforces per-user project scoping for incus group members.
    # ---------------------------------------------------------------------------
    users.users = lib.mapAttrs (username: userCfg: {
      isNormalUser = true;
      home         = "/home/${username}";
      createHome   = true;
      # nologin shell — ForceCommand overrides for SSH; console logins are rejected.
      shell        = pkgs.shadow;
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
    # SSH: one Match block per user
    # ForceCommand = plain bwrapped incus (no wrapper script).
    # Authorization is handled entirely by the daemon scriptlet.
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
