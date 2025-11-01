# hosts/hypervisor/postgres.nix
# PostgreSQL database configuration for session management
{ config, pkgs, ... }:
{
  # Enable PostgreSQL
  services.postgresql = {
    enable = true;
    package = pkgs.postgresql_15;

    # Listen only on localhost (no VM access)
    enableTCPIP = true;

    # PostgreSQL configuration
    settings = {
      # Listen only on localhost
      listen_addresses = "localhost";

      # Connection limits
      max_connections = 100;

      # Memory settings
      shared_buffers = "256MB";
      effective_cache_size = "1GB";
    };

    # Authentication configuration
    # Only allow local connections
    authentication = pkgs.lib.mkOverride 10 ''
      # TYPE  DATABASE        USER            ADDRESS                 METHOD

      # "local" is for Unix domain socket connections only
      local   all             all                                     peer

      # IPv4 local connections:
      host    all             all             127.0.0.1/32            scram-sha-256
    '';

    # Database initialization
    ensureDatabases = [ "sessiondb" ];

    ensureUsers = [
      {
        name = "sessionuser";
        ensureDBOwnership = true;
      }
    ];
  };

  # PostgreSQL automated backups
  services.postgresqlBackup = {
    enable = true;

    # Backup location
    location = "/var/backup/postgresql";

    # Backup only the sessiondb database
    databases = [ "sessiondb" ];

    # Run daily at 2:00 AM
    startAt = "*-*-* 02:00:00";

    # Use zstd compression for better compression ratios
    compression = "zstd";
    compressionLevel = 9;

    # pg_dump options: -C = include CREATE DATABASE commands
    pgdumpOptions = "-C";
  };

  # Set password for sessionuser
  # This should be done separately for security, but for initial setup:
  systemd.services.set-sessionuser-password = {
    description = "Set password for sessionuser";
    after = [ "postgresql.service" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      User = "postgres";
    };

    script = ''
      set -euo pipefail

      # Wait for PostgreSQL to be ready
      until ${pkgs.postgresql_15}/bin/psql -U postgres -c "SELECT 1" > /dev/null 2>&1; do
        echo "Waiting for PostgreSQL to be ready..."
        sleep 1
      done

      # Set password (change this to a secure password!)
      # In production, use a secrets manager instead
      ${pkgs.postgresql_15}/bin/psql -U postgres <<'EOF'
        ALTER USER sessionuser WITH PASSWORD 'sessionpass123';
      EOF

      echo "Password set for sessionuser"
    '';
  };
}
