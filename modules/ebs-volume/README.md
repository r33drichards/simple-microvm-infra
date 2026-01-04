# EBS Volume Management Module

A NixOS module for automatic management of AWS EBS volumes with ZFS filesystem support. This module handles the complete lifecycle of EBS volumes: creation, attachment, ZFS pool/dataset creation, and mounting.

## Features

- **Automatic EBS Volume Management**: Creates volumes if they don't exist, attaches them to the instance
- **ZFS Integration**: Creates ZFS pools and datasets with optimized settings
- **Idempotent Operations**: Safe to run multiple times, handles existing volumes gracefully
- **AWS Nitro Support**: Properly detects NVMe block devices on modern EC2 instances
- **Retry Logic**: Built-in retries for AWS API calls to handle transient failures
- **Configurable**: Extensive options for volume type, IOPS, throughput, encryption, and more

## Usage

### Basic Example

```nix
{ ... }:
{
  imports = [ ./modules/ebs-volume ];

  services.ebsVolumes = {
    enable = true;
    volumes."my-data" = {
      mountPoint = "/var/lib/data";
      sizeGiB = 50;
      poolName = "tank";
      dataset = "data";
      volumeType = "gp3";
      throughput = 125;
      iops = 3000;
      encrypted = true;
      mountOptions = [ "nofail" "defaults" ];
      mountOwner = "myuser";
      mountGroup = "users";
      mountDirMode = "0775";
    };
  };
}
```

### Multiple Volumes

```nix
services.ebsVolumes = {
  enable = true;
  volumes = {
    "data-volume" = {
      mountPoint = "/var/lib/data";
      sizeGiB = 100;
      poolName = "data-pool";
      dataset = "data";
      device = "/dev/sdf";
    };
    "backup-volume" = {
      mountPoint = "/var/lib/backups";
      sizeGiB = 200;
      poolName = "backup-pool";
      dataset = "backups";
      device = "/dev/sdg";
    };
  };
}
```

## Configuration Options

### Per-Volume Options

- **`enable`** (bool, default: true): Enable management of this volume
- **`mountPoint`** (path): Where to mount the ZFS dataset
- **`sizeGiB`** (int, default: 20): Volume size in GiB (only used when creating new volumes)
- **`poolName`** (string, default: volume name): ZFS pool name
- **`dataset`** (string, default: volume name): ZFS dataset name within the pool
- **`volumeType`** (enum, default: "gp3"): EBS volume type (gp3, gp2, io2, io1, st1, sc1, standard)
- **`iops`** (int or null, default: null): Provisioned IOPS for io1/io2/gp3 volumes
- **`throughput`** (int or null, default: null): Throughput in MiB/s for gp3 volumes
- **`encrypted`** (bool, default: false): Enable EBS encryption
- **`kmsKeyId`** (string or null, default: null): KMS key for encryption
- **`mountOptions`** (list of strings, default: ["nofail"]): Mount options for the ZFS dataset
- **`mountOwner`** (string or null, default: null): Owner of the mounted directory
- **`mountGroup`** (string or null, default: null): Group of the mounted directory
- **`mountDirMode`** (string or null, default: null): Permission mode for the mounted directory
- **`device`** (string, default: "/dev/sdf"): Device name for attachment

## How It Works

1. **Volume Discovery**: Uses the volume name as an AWS Name tag to find existing volumes in the same availability zone
2. **Creation**: If no volume exists, creates one with the specified configuration
3. **Attachment**: Attaches the volume to the current EC2 instance
4. **Device Detection**: Finds the NVMe block device corresponding to the volume
5. **ZFS Setup**:
   - Loads ZFS kernel module
   - Imports existing pool or creates new one with optimized settings
   - Creates dataset with legacy mountpoint
6. **Mounting**: Mounts the ZFS dataset at the specified mount point
7. **Permissions**: Sets ownership and permissions if configured

## ZFS Configuration

The module creates ZFS pools with the following optimized settings:

- `ashift=12`: Optimized for 4K sectors
- `compression=zstd`: Modern compression algorithm
- `xattr=sa`: Extended attributes stored in system attributes
- `acltype=posixacl`: POSIX ACLs support
- `atime=off`: Disabled access time updates for performance
- `mountpoint=none`: Pool-level mountpoint disabled (datasets have their own)

## Requirements

- Running on AWS EC2 instance
- IAM permissions for EC2 volume operations (describe, create, attach)
- Network access to EC2 metadata service and AWS API
- NixOS with ZFS support

## Systemd Integration

Each volume gets a systemd service unit (`ebs-volume-<name>.service`) that:
- Runs at boot (after network is online)
- Is idempotent (can be restarted safely)
- Remains active after completion
- Can be manually triggered with `systemctl start ebs-volume-<name>`

## Troubleshooting

### Volume not mounting
- Check systemd service status: `systemctl status ebs-volume-<name>`
- View logs: `journalctl -u ebs-volume-<name>`
- Verify IAM permissions for EC2 volume operations
- Ensure instance has network access to AWS API

### ZFS module not loading
- Run `nixos-rebuild switch` to rebuild with ZFS support
- Check kernel module: `lsmod | grep zfs`
- Verify ZFS is in `boot.supportedFilesystems`

### Multiple volumes with same name
The module finds volumes by Name tag within the same availability zone. Ensure unique names or clean up old volumes.

## See Also

- [example.nix](./example.nix): Complete example configuration
- [ZFS on NixOS](https://nixos.wiki/wiki/ZFS)
- [AWS EBS Documentation](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/AmazonEBS.html)
2