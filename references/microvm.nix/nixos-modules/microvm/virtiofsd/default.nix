{ config, lib, pkgs, ... }:

let
  virtiofsShares = builtins.filter ({ proto, ... }:
    proto == "virtiofs"
  ) config.microvm.shares;

  requiresVirtiofsd = virtiofsShares != [];

  inherit (pkgs.python3Packages) supervisor;
  supervisord = lib.getExe' supervisor "supervisord";
  supervisorctl = lib.getExe' supervisor "supervisorctl";
in
{
  microvm.binScripts = lib.mkIf requiresVirtiofsd {
    virtiofsd-run =
      let
        supervisordConfig = {
          supervisord.nodaemon = true;

          "eventlistener:notify" = {
            command = pkgs.writers.writePython3 "supervisord-event-handler" { } (
              pkgs.replaceVars  ./supervisord-event-handler.py {
                # 1 for the event handler process
                virtiofsdCount = 1 + builtins.length virtiofsShares;
              }
            );
            events = "PROCESS_STATE";
          };
        } // builtins.listToAttrs (
          map ({ tag, socket, source, readOnly, ... }: {
            name = "program:virtiofsd-${tag}";
            value = {
              stderr_syslog = true;
              stdout_syslog = true;
              autorestart = true;
              command = pkgs.writeShellScript "virtiofsd-${tag}" ''
                if [ $(id -u) = 0 ]; then
                  OPT_RLIMIT="--rlimit-nofile 1048576"
                else
                  OPT_RLIMIT=""
                fi
                exec ${lib.getExe pkgs.virtiofsd} \
                  --socket-path=${lib.escapeShellArg socket} \
                  ${lib.optionalString (config.microvm.virtiofsd.group != null)
                  "--socket-group=${config.microvm.virtiofsd.group}"
                  } \
                  --shared-dir=${lib.escapeShellArg source} \
                  $OPT_RLIMIT \
                  --thread-pool-size ${toString config.microvm.virtiofsd.threadPoolSize} \
                  --posix-acl --xattr \
                  ${lib.optionalString (config.microvm.virtiofsd.inodeFileHandles != null)
                    "--inode-file-handles=${config.microvm.virtiofsd.inodeFileHandles}"
                  } \
                  ${lib.optionalString (config.microvm.hypervisor == "crosvm")
                    "--tag=${tag}"
                  } \
                  ${lib.optionalString readOnly "--readonly"} \
                  ${lib.concatStringsSep " " config.microvm.virtiofsd.extraArgs}
              '';
            };
          }) virtiofsShares
        );

        supervisordConfigFile =
          pkgs.writeText "${config.networking.hostName}-virtiofsd-supervisord.conf" (
            lib.generators.toINI {} supervisordConfig
          );

      in ''
        exec ${supervisord} --configuration ${supervisordConfigFile}
      '';

    virtiofsd-shutdown = ''
      exec ${supervisorctl} stop
    '';
  };
}
