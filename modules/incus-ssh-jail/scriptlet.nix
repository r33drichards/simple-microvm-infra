# modules/incus-ssh-jail/scriptlet.nix
#
# Generates the Starlark authorization scriptlet for incusd.
# This runs inside the daemon and is evaluated on every API call.
# Protocol "unix" = Unix socket connection; Username = OS username.
#
# Jailed users (in the `incus` group) are auto-scoped to their own project
# by the daemon. The scriptlet further restricts which operations they may
# perform within that project.
{ lib, users }:

let
  # Build a Starlark list literal from the user set, evaluated at Nix eval
  # time so the scriptlet is a static string with no runtime indirection.
  userList = "[" + lib.concatStringsSep ", "
    (map (u: ''"${u}"'') (builtins.attrNames users))
    + "]";
in ''
  # Jailed Unix socket users — populated from NixOS config at eval time.
  JAILED_USERS = ${userList}

  # Permitted entitlements per resource type.
  # Full entitlement list: https://linuxcontainers.org/incus/docs/main/authorization/
  ALLOWED = {
      "instance": [
          "can_view",
          "can_update_state",    # start / stop / restart / pause
          "can_exec",            # incus exec
          "can_access_console",  # incus console
          "can_access_files",    # incus file push/pull
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
      # Non-Unix-socket connections (TLS, etc.) use their own auth path.
      if details.Protocol != "unix":
          return True

      # Non-jailed users (operators, admins) pass through unrestricted.
      if details.Username not in JAILED_USERS:
          return True

      # server-level entitlements (e.g. can_view metrics) — allow read-only
      if object == "server":
          return entitlement in ["can_view", "can_view_resources",
                                 "can_view_metrics", "authenticated"]

      return entitlement in ALLOWED.get(object, [])
''
