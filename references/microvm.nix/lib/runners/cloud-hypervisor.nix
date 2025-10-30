{ pkgs
, microvmConfig
, macvtapFds
, extractOptValues
, extractParamValue
, ...
}:

let
  inherit (pkgs) lib;
  inherit (microvmConfig) vcpu mem balloon initialBalloonMem deflateOnOOM hotplugMem hotpluggedMem user interfaces volumes shares socket devices hugepageMem graphics storeDisk storeOnDisk kernel initrdPath credentialFiles vsock;
  inherit (microvmConfig.cloud-hypervisor) platformOEMStrings extraArgs;

  # extract all the extra args that we merge with up front
  processedExtraArgs = builtins.foldl'
    (args: opt: (extractOptValues opt args).args)
    extraArgs
    ["--vsock" "--platform"];

  hasUserConsole = (extractOptValues "--console" extraArgs).values != [];
  hasUserSerial = (extractOptValues "--serial" extraArgs).values != [];
  userSerial = lib.optionalString hasUserSerial (extractOptValues "--serial" extraArgs).values;

  kernelPath = {
    x86_64-linux = "${kernel.dev}/vmlinux";
    aarch64-linux = "${kernel.out}/${pkgs.stdenv.hostPlatform.linux-kernel.target}";
  }.${pkgs.stdenv.system};

  kernelConsoleDefault =
    if pkgs.stdenv.system == "x86_64-linux"
    then "earlyprintk=ttyS0 console=ttyS0"
    else if pkgs.stdenv.system == "aarch64-linux"
    then "console=ttyAMA0"
    else "";

  kernelConsole = lib.optionalString (!hasUserSerial || userSerial == "tty") kernelConsoleDefault;

  kernelCmdLine = "${kernelConsole} reboot=t panic=-1 ${toString microvmConfig.kernelParams}";


  userVSockOpts = (extractOptValues "--vsock" extraArgs).values;
  userVSockStr = if userVSockOpts == [] then null else builtins.head userVSockOpts;
  userVSockPath = extractParamValue "socket" userVSockStr;
  userVSockCID = extractParamValue "cid" userVSockStr;
  vsockCID = if vsock.cid != null && userVSockCID != null
             then throw "Cannot set `microvm.vsock.cid` and --vsock 'cid=${userVSockCID}...' via `microvm.cloud-hypervisor.extraArgs` at the same time"
             else if vsock.cid != null
                  then vsock.cid
                  else userVSockCID;
  supportsNotifySocket = vsockCID != null;
  vsockPath = if userVSockPath != null then userVSockPath else "notify.vsock";
  vsockOpts =
    if vsockCID == null then
      lib.warn "cloud-hypervisor supports systemd-notify via vsock, but `microvm.vsock.cid` must be set to enable this." ""
    else
      "cid=${toString vsockCID},socket=${vsockPath}";

  useHotPlugMemory = hotplugMem > 0;

  useVirtiofs = builtins.any ({ proto, ... }: proto == "virtiofs") shares;

  # Transform attrs to parameters in form of `key1=value1,key2=value2,[...]`
  opsMapped = ops: lib.concatStringsSep "," (
    lib.mapAttrsToList (k: v:
      "${k}=${v}"
    ) ops
  );

  # Attrs representing CHV mem options
  memOps = opsMapped ({
    size = "${toString mem}M";
    mergeable = "on";
    # Shared memory is required for usage with virtiofsd but it
    # prevents Kernel Same-page Merging.
    shared = if useVirtiofs || graphics.enable then "on" else "off";
  }
  # add ballooning options and override 'size' key
  // lib.optionalAttrs useHotPlugMemory {
    size = "${toString hotplugMem}M";
    hotplug_method = "virtio-mem";
    hotplug_size = "${toString hotplugMem}M";
    hotplugged_size = "${toString hotpluggedMem}M";
  }
  # enable hugepages (shared option is ignored by CHV)
  // lib.optionalAttrs hugepageMem {
    hugepages = "on";
  });

  balloonOps = opsMapped ({
    size = "${toString initialBalloonMem}M";
    free_page_reporting = "on";
  }
  # enable deflating memory balloon on out-of-memory
  // lib.optionalAttrs deflateOnOOM {
    deflate_on_oom = "on";
  });

  tapMultiQueue = vcpu > 1;

  # Multi-queue options
  mqOps = lib.optionalAttrs tapMultiQueue {
    num_queues = toString vcpu;
  };

  # cloud-hypervisor >= 30.0 < 36.0 temporarily replaced clap with argh
  hasArghSyntax =
    builtins.compareVersions pkgs.cloud-hypervisor.version "30.0" >= 0 &&
    builtins.compareVersions pkgs.cloud-hypervisor.version "36.0" < 0;
  arg =
    if hasArghSyntax
    then switch: params:
      # `--switch param0 --switch param1 ...`
      builtins.concatMap (param: [ switch param ]) params
    else switch: params:
      # `` or `--switch param0 param1 ...`
      lib.optionals (params != []) (
        [ switch ] ++ params
      );

  gpuParams = {
    context-types = "virgl:virgl2:cross-domain";
    displays = [ {
      hidden = true;
    } ];
    egl = true;
    vulkan = true;
  };

  oemStringValues = platformOEMStrings ++ lib.optional supportsNotifySocket "io.systemd.credential:vmm.notify_socket=vsock-stream:2:8888";
  oemStringOptions = lib.optional (oemStringValues != []) "oem_strings=[${lib.concatStringsSep "," oemStringValues}]";
  platformExtracted = extractOptValues "--platform" extraArgs;
  extraArgsWithoutPlatform = platformExtracted.args;
  userPlatformOpts = platformExtracted.values;
  userPlatformStr = lib.optionalString (userPlatformOpts != []) (builtins.head userPlatformOpts);
  userHasOemStrings = (extractParamValue "oem_strings" userPlatformStr) != null;
  platformOps =
    if userHasOemStrings then
      throw "Use `microvm.cloud-hypervisor.platformOEMStrings` instead of passing oem_strings via --platform"
    else
      lib.concatStringsSep "," (oemStringOptions ++ userPlatformOpts);
in {
  inherit tapMultiQueue supportsNotifySocket;

  preStart = ''
    ${microvmConfig.preStart}
    ${lib.optionalString (socket != null) ''
      # workaround cloud-hypervisor sometimes
      # stumbling over a preexisting socket
      rm -f '${socket}'
    ''}

  '' + lib.optionalString supportsNotifySocket ''
    # Ensure notify sockets are removed if cloud-hypervisor didn't exit cleanly the last time
    rm -f ${vsockPath} ${vsockPath}_8888

    # Start socat to forward systemd notify socket over vsock
    if [ -n "''${NOTIFY_SOCKET:-}" ]; then
      # -T2 is required because cloud-hypervisor does not handle partial
      # shutdown of the stream, like systemd v256+ does.
      ${pkgs.socat}/bin/socat -T2 UNIX-LISTEN:${vsockPath}_8888,fork UNIX-SENDTO:$NOTIFY_SOCKET &
    fi
  '' + lib.optionalString graphics.enable ''
    rm -f ${graphics.socket}
    ${pkgs.crosvm}/bin/crosvm device gpu \
      --socket ${graphics.socket} \
      --wayland-sock $XDG_RUNTIME_DIR/$WAYLAND_DISPLAY \
      --params '${builtins.toJSON gpuParams}' \
      &
    while ! [ -S ${graphics.socket} ]; do
      sleep .1
    done
  '';


  command =
    if user != null
    then throw "cloud-hypervisor will not change user"
    else if credentialFiles != {}
    then throw "cloud-hypervisor does not support credentialFiles"
    else lib.escapeShellArgs (
      [
        (if graphics.enable
         then "${pkgs.cloud-hypervisor-graphics}/bin/cloud-hypervisor"
         else "${pkgs.cloud-hypervisor}/bin/cloud-hypervisor"
        )
        "--cpus" "boot=${toString vcpu}"
        "--watchdog"
        "--kernel" kernelPath
        "--initramfs" initrdPath
        "--cmdline" kernelCmdLine
        "--seccomp" "true"
        "--memory" memOps
        "--platform" platformOps
      ]
      ++
      lib.optionals (!hasUserConsole) ["--console" "null"]
      ++
      lib.optionals (!hasUserSerial) ["--serial" "tty"]
      ++
      lib.optionals (vsockOpts != "") ["--vsock" vsockOpts]
      ++
      lib.optionals graphics.enable [
        "--gpu" "socket=${graphics.socket}"
      ]
      ++
      lib.optionals balloon [ "--balloon" balloonOps ]
      ++
      arg "--disk" (
        lib.optional storeOnDisk (opsMapped ({
          path = toString storeDisk;
          readonly = "on";
        } // mqOps))
        ++
        map ({ image, serial, direct, readOnly, ... }:
          opsMapped (
            {
              path = toString image;
              direct =
                if direct
                then "on"
                else "off";
              readonly =
                if readOnly
                then "on"
                else "off";
            } //
            lib.optionalAttrs (serial != null) {
              inherit serial;
            } //
            mqOps
          )
        ) volumes
      )
      ++
      arg "--fs" (map ({ proto, socket, tag, ... }:
        if proto == "virtiofs"
        then opsMapped {
          inherit tag socket;
        }
        else throw "cloud-hypervisor supports only shares that are virtiofs"
      ) shares)
      ++
      lib.optionals (socket != null) [ "--api-socket" socket ]
      ++
      arg "--net" (map ({ type, id, mac, ... }:
        if type == "tap"
        then opsMapped ({
          tap = id;
          inherit mac;
        } // lib.optionalAttrs tapMultiQueue {
          num_queues = toString (2 * vcpu);
        })
        else if type == "macvtap"
        then opsMapped ({
          fd = "[${lib.concatMapStringsSep "," toString macvtapFds.${id}}]";
          inherit mac;
        } // lib.optionalAttrs tapMultiQueue {
          num_queues = toString (2 * vcpu);
        })
        else throw "Unsupported interface type ${type} for Cloud-Hypervisor"
      ) interfaces)
    )
    + " " + # Move vfio-pci outside of
    lib.concatStringsSep " " (
      arg "--device" (
        map ({ bus, path, ... }: {
          pci = "path=/sys/bus/pci/devices/${path}";
          usb = throw "USB passthrough is not supported on cloud-hypervisor";
        }.${bus}) devices
      )
    ) + " " + lib.escapeShellArgs processedExtraArgs;

  canShutdown = socket != null;

  shutdownCommand =
    if socket != null
    then ''
        api() {
          ${pkgs.curl}/bin/curl -s \
            --unix-socket ${socket} \
            $@
        }

        api -X PUT http://localhost/api/v1/vm.power-button

        ${pkgs.util-linux}/bin/waitpid $MAINPID
      ''
    else throw "Cannot shutdown without socket";

  setBalloonScript =
    if socket != null
    then ''
      ${pkgs.cloud-hypervisor}/bin/ch-remote --api-socket ${socket} resize --balloon $SIZE"M"
    ''
    else null;

  requiresMacvtapAsFds = true;
}
