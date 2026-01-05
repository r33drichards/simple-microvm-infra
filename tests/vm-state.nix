{ pkgs ? import <nixpkgs> {}
, vm-state
}:

# NixOS Integration Test for vm-state CLI
#
# Tests the C++ vm-state CLI with a real ZFS pool and systemd services.
# This creates a VM with ZFS support and runs through all the CLI commands.

pkgs.nixosTest {
  name = "vm-state-integration";

  nodes.machine = { config, pkgs, lib, ... }: {
    # Enable ZFS support
    boot.supportedFilesystems = [ "zfs" ];
    boot.zfs.forceImportRoot = false;
    networking.hostId = "12345678";

    # Create a virtual disk for ZFS testing
    virtualisation = {
      emptyDiskImages = [ 512 ];  # 512MB disk for ZFS pool
      memorySize = 1024;
    };

    # Add our vm-state package
    environment.systemPackages = [
      vm-state
      pkgs.zfs
    ];

    # Create a dummy microvm service to test systemd integration
    systemd.services."microvm@" = {
      description = "Test MicroVM Service %i";
      serviceConfig = {
        Type = "simple";
        ExecStart = "${pkgs.coreutils}/bin/sleep infinity";
        RemainAfterExit = true;
      };
    };

    # Create required users and groups
    users.groups.kvm = {};
    users.users.microvm = {
      isSystemUser = true;
      group = "kvm";
    };

    # Ensure directory structure exists
    systemd.tmpfiles.rules = [
      "d /var/lib/microvms 0755 microvm kvm -"
      "d /var/lib/microvms/states 0755 microvm kvm -"
      "d /var/lib/microvms/slot1 0755 microvm kvm -"
      "d /var/lib/microvms/slot2 0755 microvm kvm -"
    ];
  };

  testScript = ''
    machine.start()
    machine.wait_for_unit("multi-user.target")

    # Create a ZFS pool on the virtual disk
    machine.succeed("modprobe zfs")
    machine.succeed("zpool create -f microvms /dev/vdb")
    machine.succeed("zfs create microvms/storage")
    machine.succeed("zfs create -o mountpoint=/var/lib/microvms/states microvms/storage/states")
    machine.succeed("chown -R microvm:kvm /var/lib/microvms")

    # Test: vm-state help
    machine.succeed("vm-state help")
    machine.succeed("vm-state --help")

    # Test: vm-state list (should work with empty state)
    result = machine.succeed("vm-state list")
    assert "States and assignments" in result, "List should show header"

    # Test: vm-state create
    machine.succeed("vm-state create test-state")
    result = machine.succeed("vm-state list")
    assert "test-state" in result, "Created state should appear in list"

    # Verify ZFS dataset was created
    machine.succeed("zfs list microvms/storage/states/test-state")

    # Test: vm-state snapshot
    # First, we need to assign a state to a slot
    machine.succeed("vm-state assign slot1 test-state")

    # Verify symlink was created
    machine.succeed("test -L /var/lib/microvms/slot1/data.img")

    # Create a snapshot
    machine.succeed("vm-state snapshot slot1 snap1")

    # Verify snapshot exists
    machine.succeed("zfs list -t snapshot microvms/storage/states/test-state@snap1")

    # Test: vm-state clone
    machine.succeed("vm-state clone test-state cloned-state")
    machine.succeed("zfs list microvms/storage/states/cloned-state")

    # Test: vm-state restore
    machine.succeed("vm-state restore snap1 restored-state")
    machine.succeed("zfs list microvms/storage/states/restored-state")

    # Test: Start a dummy microvm service
    machine.succeed("systemctl start microvm@slot1.service")
    machine.succeed("systemctl is-active microvm@slot1.service")

    # Test: vm-state migrate (stops, assigns, starts)
    machine.succeed("vm-state migrate cloned-state slot2")
    machine.succeed("test -L /var/lib/microvms/slot2/data.img")

    # Verify slot2 service is running after migrate
    machine.succeed("systemctl is-active microvm@slot2.service")

    # Test: vm-state delete (should fail if in use)
    machine.fail("echo 'DELETE' | vm-state delete cloned-state")

    # Reassign slot2 to test-state so we can delete cloned-state
    machine.succeed("systemctl stop microvm@slot2.service")
    machine.succeed("vm-state assign slot2 test-state")

    # Now delete should work (with confirmation)
    machine.succeed("echo 'DELETE' | vm-state delete cloned-state")
    machine.fail("zfs list microvms/storage/states/cloned-state")

    # Cleanup - delete restored state
    machine.succeed("echo 'DELETE' | vm-state delete restored-state")

    print("All vm-state integration tests passed!")
  '';
}
