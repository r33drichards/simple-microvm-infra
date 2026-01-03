{ config, lib, pkgs, ... }:

let
  cfg = config.services.ebsVolumes;

  # Escape a string for systemd unit names
  escapeUnit = s: lib.replaceStrings ["/" " "] ["-" "-"] s;

  volumeSubmodule = { name, ... }: {
    options = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Enable management of this EBS volume.";
      };

      # The attribute key of this submodule (`name`) is used as the Name tag.

      mountPoint = lib.mkOption {
        type = lib.types.path;
        description = "Absolute path where the volume will be mounted.";
        example = "/var/lib/data";
      };

      sizeGiB = lib.mkOption {
        type = lib.types.ints.positive;
        default = 20;
        description = "Size of the EBS volume in GiB when creating a new volume.";
      };

      poolName = lib.mkOption {
        type = lib.types.str;
        default = name;
        description = "ZFS pool name to create/import on this EBS volume.";
      };

      dataset = lib.mkOption {
        type = lib.types.str;
        default = name;
        description = "ZFS dataset name within the pool to mount at mountPoint.";
      };

      volumeType = lib.mkOption {
        type = lib.types.enum [ "gp3" "gp2" "io2" "io1" "st1" "sc1" "standard" ];
        default = "gp3";
        description = "AWS EBS volume type when creating a new volume.";
      };

      iops = lib.mkOption {
        type = lib.types.nullOr lib.types.ints.positive;
        default = null;
        description = "Provisioned IOPS (required for some volume types).";
      };

      throughput = lib.mkOption {
        type = lib.types.nullOr lib.types.ints.positive;
        default = null;
        description = "Provisioned throughput in MiB/s (gp3 only).";
      };

      encrypted = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Whether to encrypt the volume when creating it.";
      };

      kmsKeyId = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "KMS key ID/ARN for encryption (when encrypted = true).";
      };

      mountOptions = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ "nofail" ];
        description = "Additional mount options to pass to the ZFS mount (legacy).";
      };

      # Optional ownership/permissions for the mounted directory
      mountOwner = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Owner (user name or UID) for the mounted directory.";
      };

      mountGroup = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Group (group name or GID) for the mounted directory.";
      };

      mountDirMode = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Directory mode for the mounted directory (e.g., 0775).";
      };

      device = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = "/dev/sdf";
        description = "Device name for the EBS volume (e.g., /dev/sdf).";
      };

      childDatasets = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [];
        description = ''
          List of child dataset names to create under the main dataset.
          Each child dataset can be independently snapshotted.
          Example: [ "vm1" "vm2" ] creates pool/dataset/vm1, pool/dataset/vm2
        '';
        example = [ "vm1" "vm2" "vm3" ];
      };
    };
  };

  # (intentionally empty; legacy helper removed)

in
{
  options.services.ebsVolumes = {
    enable = lib.mkEnableOption "Manage and mount EBS volumes by Name tag.";

    volumes = lib.mkOption {
      type = lib.types.attrsOf (lib.types.submodule volumeSubmodule);
      default = {};
      description = "Set of EBS volumes to ensure exist, attach, and mount.";
    };
  };

  config = lib.mkIf cfg.enable (
    let
      vols = lib.filterAttrs (_: v: v.enable) cfg.volumes;
      ensureUnits = lib.mapAttrsToList (
        name: v:
        let
          tagName = name;
          unitName = "ebs-volume-" + escapeUnit tagName;
          ensureScript = pkgs.writeShellScript unitName ''
            set -euo pipefail

            NAME_TAG=${lib.escapeShellArg tagName}
            SIZE_GIB=${toString v.sizeGiB}
            POOL=${lib.escapeShellArg v.poolName}
            DATASET=${lib.escapeShellArg v.dataset}

            AWS=${lib.getExe pkgs.awscli2}
            CURL=${lib.getExe pkgs.curl}
            JQ=${lib.getExe pkgs.jq}
            NVME=${lib.getExe pkgs.nvme-cli}
            MODPROBE=${lib.getExe' pkgs.kmod "modprobe"}
            ZPOOL=${pkgs.zfs}/bin/zpool
            ZFS=${pkgs.zfs}/bin/zfs
            CHOWN=${pkgs.coreutils}/bin/chown
            CHMOD=${pkgs.coreutils}/bin/chmod

            # Ensure mount point exists
            mkdir -p ${lib.escapeShellArg (toString v.mountPoint)}

            # Get IMDSv2 token (required for instances with IMDSv2 enforcement)
            IMDS_TOKEN=$($CURL -s -X PUT "http://169.254.169.254/latest/api/token" \
              -H "X-aws-ec2-metadata-token-ttl-seconds: 300")

            # Metadata using IMDSv2
            IID=$($CURL -s -H "X-aws-ec2-metadata-token: $IMDS_TOKEN" \
              http://169.254.169.254/latest/meta-data/instance-id)
            REGION=$($CURL -s -H "X-aws-ec2-metadata-token: $IMDS_TOKEN" \
              http://169.254.169.254/latest/dynamic/instance-identity/document | $JQ -r .region)
            AZ=$($CURL -s -H "X-aws-ec2-metadata-token: $IMDS_TOKEN" \
              http://169.254.169.254/latest/meta-data/placement/availability-zone)

            # Lookup the most recent volume by Name tag within this AZ.
            # Add retries to avoid transient AWS API/network issues that could
            # incorrectly return no results and cause duplicate creations.
            VOLUME_ID=""
            for attempt in $(seq 1 8); do
              VOLUME_ID=$($AWS ec2 describe-volumes \
                --region "$REGION" \
                --filters \
                  Name=tag:Name,Values="$NAME_TAG" \
                  Name=availability-zone,Values="$AZ" \
                  Name=status,Values=available,in-use \
                --query 'sort_by(Volumes, &CreateTime)[-1].VolumeId' \
                --output text 2>/dev/null || true)

              if [ -n "$VOLUME_ID" ] && [ "$VOLUME_ID" != "None" ]; then
                break
              fi
              sleep $((attempt))
            done

            if [ -z "$VOLUME_ID" ] || [ "$VOLUME_ID" = "None" ]; then
              echo "Creating EBS volume Name=$NAME_TAG size=${toString v.sizeGiB}GiB type=${v.volumeType} in $AZ"
              CREATE_ARGS=(
                --region "$REGION"
                --availability-zone "$AZ"
                --size "$SIZE_GIB"
                --volume-type ${lib.escapeShellArg v.volumeType}
                --tag-specifications "ResourceType=volume,Tags=[{Key=Name,Value=$NAME_TAG}]"
              )
              ${lib.optionalString (v.iops != null) ''CREATE_ARGS+=(--iops "${toString v.iops}")''}
              ${lib.optionalString (v.throughput != null) ''CREATE_ARGS+=(--throughput "${toString v.throughput}")''}
              ${lib.optionalString v.encrypted ''CREATE_ARGS+=(--encrypted)''}
              ${lib.optionalString (v.kmsKeyId != null) ''CREATE_ARGS+=(--kms-key-id ${lib.escapeShellArg (v.kmsKeyId or "")})''}

              VOLUME_JSON=$($AWS ec2 create-volume "''${CREATE_ARGS[@]}" 2>/dev/null || true)
              VOLUME_ID=$(echo "$VOLUME_JSON" | $JQ -r .VolumeId)
              # Wait until the volume becomes available before attaching
              if [ -n "$VOLUME_ID" ] && [ "$VOLUME_ID" != "null" ]; then
                $AWS ec2 wait volume-available --region "$REGION" --volume-ids "$VOLUME_ID"
              fi
            fi

            if [ -z "$VOLUME_ID" ] || [ "$VOLUME_ID" = "null" ]; then
              echo "Failed to obtain VolumeId for Name=$NAME_TAG" >&2
              exit 1
            fi

            echo "Ensuring volume $VOLUME_ID is attached to $IID"

            # Check current attachment state
            VOLUME_INFO=$($AWS ec2 describe-volumes --region "$REGION" --volume-ids "$VOLUME_ID" --output json)
            CURRENT_INSTANCE=$(echo "$VOLUME_INFO" | $JQ -r '.Volumes[0].Attachments[0].InstanceId // empty')
            ATTACH_STATE=$(echo "$VOLUME_INFO" | $JQ -r '.Volumes[0].Attachments[0].State // empty')

            if [ "$CURRENT_INSTANCE" = "$IID" ] && [ "$ATTACH_STATE" = "attached" ]; then
              echo "Volume already attached to this instance"
            elif [ -n "$CURRENT_INSTANCE" ] && [ "$CURRENT_INSTANCE" != "$IID" ]; then
              # Volume attached to different instance - check if that instance is dead
              OTHER_STATE=$($AWS ec2 describe-instances --region "$REGION" --instance-ids "$CURRENT_INSTANCE" \
                --query 'Reservations[0].Instances[0].State.Name' --output text 2>/dev/null || echo "terminated")

              if [ "$OTHER_STATE" = "terminated" ] || [ "$OTHER_STATE" = "shutting-down" ] || [ "$OTHER_STATE" = "stopped" ]; then
                echo "Volume attached to dead/stopped instance $CURRENT_INSTANCE ($OTHER_STATE), force detaching..."
                $AWS ec2 detach-volume --region "$REGION" --volume-id "$VOLUME_ID" --force >/dev/null || true
                echo "Waiting for volume to become available..."
                $AWS ec2 wait volume-available --region "$REGION" --volume-ids "$VOLUME_ID"
              else
                echo "ERROR: Volume is attached to running instance $CURRENT_INSTANCE" >&2
                exit 1
              fi

              # Now attach to this instance
              $AWS ec2 attach-volume --region "$REGION" --volume-id "$VOLUME_ID" --instance-id "$IID" --device ${lib.escapeShellArg v.device} >/dev/null
              echo "Waiting for volume to be in-use..."
              $AWS ec2 wait volume-in-use --region "$REGION" --volume-ids "$VOLUME_ID"
            else
              # Volume is available or in unknown state, try to attach
              $AWS ec2 attach-volume --region "$REGION" --volume-id "$VOLUME_ID" --instance-id "$IID" --device ${lib.escapeShellArg v.device} >/dev/null 2>&1 || true
              echo "Waiting for volume to be in-use..."
              $AWS ec2 wait volume-in-use --region "$REGION" --volume-ids "$VOLUME_ID"
            fi

            # Find the nvme device that corresponds to this volume (retry for a while)
            # On Nitro, the NVMe serial uses the volume ID WITHOUT the hyphen (e.g., vol0123...)
            VOLUME_ID_NOHYPHEN=$(echo "$VOLUME_ID" | tr -d '-')
            DEVICE=""
            for i in $(seq 1 90); do
              # Prefer stable by-id symlink if available
              BY_ID_LINK="/dev/disk/by-id/nvme-Amazon_Elastic_Block_Store_''${VOLUME_ID_NOHYPHEN}"
              if [ -e "$BY_ID_LINK" ]; then
                DEVICE=$(readlink -f "$BY_ID_LINK")
              fi

              # Fallback: probe nvme controllers and match either hyphenated or non-hyphenated ID
              if [ -z "$DEVICE" ]; then
                for d in /dev/nvme*n1; do
                  [ -e "$d" ] || continue
                  if $NVME id-ctrl -v "$d" 2>/dev/null | grep -Eq "''${VOLUME_ID}|''${VOLUME_ID_NOHYPHEN}"; then
                    DEVICE="$d"
                    break
                  fi
                done
              fi

              [ -n "$DEVICE" ] && break
              sleep 2
            done

            if [ -z "$DEVICE" ]; then
              # Fallback: legacy xen devices (unlikely on modern Nitro, but harmless)
              # We cannot reliably detect here; rely on LABEL after first format
              echo "No block device found for EBS volume $VOLUME_ID" >&2
              exit 1
            fi

            # Ensure ZFS kernel module is loaded before using zpool/zfs
            if ! $MODPROBE zfs; then
              echo "WARNING: Failed to load ZFS kernel module. The system may need to be rebuilt." >&2
              echo "Try running 'nixos-rebuild switch' to apply kernel module configuration." >&2
              exit 1
            fi

            # Import or create ZFS pool on the device
            if $ZPOOL list -H -o name 2>/dev/null | grep -qx "$POOL"; then
              echo "ZFS pool $POOL already imported"
            else
              # Try to import existing pool from the device
              # Use -d to specify device directory for reliable import after hardware changes
              if $ZPOOL import -d /dev/disk/by-id -N "$POOL" >/dev/null 2>&1; then
                echo "Imported existing ZFS pool $POOL"
              elif $ZPOOL import -d "$(dirname "$DEVICE")" -N "$POOL" >/dev/null 2>&1; then
                echo "Imported existing ZFS pool $POOL from device directory"
              else
                # Check if the device already has a ZFS pool with different name
                EXISTING_POOL=$($ZPOOL import -d "$(dirname "$DEVICE")" 2>/dev/null | grep "pool:" | awk '{print $2}' | head -1)
                if [ -n "$EXISTING_POOL" ]; then
                  echo "WARNING: Device has existing pool '$EXISTING_POOL', expected '$POOL'"
                  echo "Importing as $EXISTING_POOL (will use existing pool name)"
                  $ZPOOL import -d "$(dirname "$DEVICE")" -N "$EXISTING_POOL" >/dev/null 2>&1 || true
                  POOL="$EXISTING_POOL"
                else
                  echo "Creating ZFS pool $POOL on $DEVICE"
                  $ZPOOL create -f \
                    -o ashift=12 \
                    -O compression=zstd \
                    -O xattr=sa \
                    -O acltype=posixacl \
                    -O atime=off \
                    -O mountpoint=none \
                    "$POOL" "$DEVICE"
                fi
              fi
            fi

            # Ensure dataset exists with legacy mountpoint
            if ! $ZFS list -H -o name "$POOL/$DATASET" >/dev/null 2>&1; then
              echo "Creating ZFS dataset $POOL/$DATASET with mountpoint=legacy"
              $ZFS create -o mountpoint=legacy "$POOL/$DATASET"
            fi

            # Ensure mount
            if ! mountpoint -q ${lib.escapeShellArg (toString v.mountPoint)}; then
              echo "Mounting ZFS dataset $POOL/$DATASET at ${toString v.mountPoint}"
              mount -t zfs -o ${lib.concatStringsSep "," v.mountOptions} "$POOL/$DATASET" ${lib.escapeShellArg (toString v.mountPoint)} || true
            fi

            # Ensure ownership/permissions if configured
            OWNER=${lib.escapeShellArg (v.mountOwner or "")}
            GROUP=${lib.escapeShellArg (v.mountGroup or "")}
            DIRMODE=${lib.escapeShellArg (v.mountDirMode or "")}

            if [ -n "$OWNER" ] || [ -n "$GROUP" ]; then
              TARGET=""
              if [ -n "$OWNER" ] && [ -n "$GROUP" ]; then
                TARGET="$OWNER:$GROUP"
              elif [ -n "$OWNER" ]; then
                TARGET="$OWNER"
              else
                TARGET=":$GROUP"
              fi
              $CHOWN "$TARGET" ${lib.escapeShellArg (toString v.mountPoint)} || true
            fi

            if [ -n "$DIRMODE" ]; then
              $CHMOD "$DIRMODE" ${lib.escapeShellArg (toString v.mountPoint)} || true
            fi

            # Create child datasets for independent snapshots
            ${lib.concatMapStringsSep "\n" (child: ''
              if ! $ZFS list -H -o name "$POOL/$DATASET/${child}" >/dev/null 2>&1; then
                echo "Creating child dataset $POOL/$DATASET/${child}"
                $ZFS create -o mountpoint=${lib.escapeShellArg (toString v.mountPoint)}/${child} "$POOL/$DATASET/${child}"
              fi
              # Ensure child dataset is mounted
              if ! mountpoint -q ${lib.escapeShellArg (toString v.mountPoint)}/${child} 2>/dev/null; then
                $ZFS mount "$POOL/$DATASET/${child}" 2>/dev/null || true
              fi
              # Apply ownership to child dataset mount if configured
              if [ -n "$OWNER" ] || [ -n "$GROUP" ]; then
                $CHOWN "$TARGET" ${lib.escapeShellArg (toString v.mountPoint)}/${child} || true
              fi
              if [ -n "$DIRMODE" ]; then
                $CHMOD "$DIRMODE" ${lib.escapeShellArg (toString v.mountPoint)}/${child} || true
              fi
            '') v.childDatasets}
          '';
        in
        {
          name = unitName;
          value = {
            description = "Ensure EBS volume ${name} exists, attached, and mounted";
            wantedBy = [ "multi-user.target" ];
            after = [ "network-online.target" ];
            wants = [ "network-online.target" ];
            before = [ "shutdown.target" "reboot.target" "halt.target" ];
            conflicts = [ "shutdown.target" "reboot.target" "halt.target" ];
            path = with pkgs; [ zfs util-linux gawk ];
            serviceConfig = {
              Type = "oneshot";
              RemainAfterExit = true;
              ExecStart = ensureScript;
              # Clean shutdown: unmount and export pool for safe detachment
              ExecStop = pkgs.writeShellScript "stop-${unitName}" ''
                set -euo pipefail
                POOL=${lib.escapeShellArg v.poolName}
                MOUNT=${lib.escapeShellArg (toString v.mountPoint)}
                ZPOOL=${pkgs.zfs}/bin/zpool

                # Unmount if mounted
                if mountpoint -q "$MOUNT" 2>/dev/null; then
                  echo "Unmounting $MOUNT"
                  umount "$MOUNT" || true
                fi

                # Export pool for clean detachment
                if $ZPOOL list -H -o name 2>/dev/null | grep -qx "$POOL"; then
                  echo "Exporting ZFS pool $POOL"
                  $ZPOOL export "$POOL" || true
                fi
              '';
            };
          };
        }
      ) vols;

    in
    {
      environment.systemPackages = [ pkgs.awscli2 pkgs.jq pkgs.curl pkgs.nvme-cli pkgs.zfs ];

      systemd.services = lib.listToAttrs ensureUnits;

      # Note: We intentionally do NOT add fileSystems entries here.
      # The ebs-volume service handles mounting directly. Adding fileSystems
      # would trigger automatic ZFS pool import before the pool exists.

      # Ensure ZFS support; ebs-volume units handle import and mounting
      boot.supportedFilesystems = [ "zfs" ];
      boot.extraModulePackages = [ config.boot.zfs.package ];

      # ZFS requires networking.hostId to be set; default it deterministically from hostname
      networking.hostId = lib.mkDefault (builtins.substring 0 8 (builtins.hashString "sha256" config.networking.hostName));
    }
  );
}
