# hosts/hypervisor/postgres.nix
# PostgreSQL database configuration for session management
{ config, pkgs, ... }:
{
  # Enable PostgreSQL
  services.postgresql = {
    enable = true;
    package = pkgs.postgresql_15;

    # Listen on all interfaces so VMs can connect
    enableTCPIP = true;

    # PostgreSQL configuration
    settings = {
      # Listen on all interfaces
      listen_addresses = "*";

      # Connection limits
      max_connections = 100;

      # Memory settings
      shared_buffers = "256MB";
      effective_cache_size = "1GB";
    };

    # Authentication configuration
    # Allow password auth from VM network ranges
    authentication = pkgs.lib.mkOverride 10 ''
      # TYPE  DATABASE        USER            ADDRESS                 METHOD

      # "local" is for Unix domain socket connections only
      local   all             all                                     peer

      # IPv4 local connections:
      host    all             all             127.0.0.1/32            scram-sha-256

      # Allow VMs to connect
      host    sessiondb       sessionuser     10.1.0.0/24             scram-sha-256
      host    sessiondb       sessionuser     10.2.0.0/24             scram-sha-256
      host    sessiondb       sessionuser     10.3.0.0/24             scram-sha-256
      host    sessiondb       sessionuser     10.4.0.0/24             scram-sha-256
      host    sessiondb       sessionuser     10.5.0.0/24             scram-sha-256
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

  # Open PostgreSQL port in firewall for VM networks
  networking.firewall.allowedTCPPorts = [ 5432 ];

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

  # Create backup directory with proper permissions
  systemd.tmpfiles.rules = [
    "d /var/backup 0755 root root -"
    "d /var/backup/postgresql 0755 postgres postgres -"
  ];

  # Initialize database schema
  # This runs after PostgreSQL starts and ensures the schema is created
  systemd.services.init-session-schema = {
    description = "Initialize session database schema";
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
      until ${pkgs.postgresql_15}/bin/psql -U postgres -d sessiondb -c "SELECT 1" > /dev/null 2>&1; do
        echo "Waiting for PostgreSQL to be ready..."
        sleep 1
      done

      # Create the inbox_status enum type if it doesn't exist
      ${pkgs.postgresql_15}/bin/psql -U postgres -d sessiondb <<'EOF'
        -- Create enum type for inbox-status if it doesn't exist
        DO $$ BEGIN
          CREATE TYPE inbox_status_enum AS ENUM ('pending', 'processing', 'completed', 'failed');
        EXCEPTION
          WHEN duplicate_object THEN null;
        END $$;

        -- Create session table if it doesn't exist
        CREATE TABLE IF NOT EXISTS session (
          id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
          messages JSONB,
          inbox_status inbox_status_enum,
          sbx_config JSONB,
          parent UUID REFERENCES session(id),
          created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
          updated_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
        );

        -- Create index on parent for faster lookups
        CREATE INDEX IF NOT EXISTS idx_session_parent ON session(parent);

        -- Create index on inbox_status for filtering
        CREATE INDEX IF NOT EXISTS idx_session_inbox_status ON session(inbox_status);

        -- Create updated_at trigger function if it doesn't exist
        CREATE OR REPLACE FUNCTION update_updated_at_column()
        RETURNS TRIGGER AS $update$
        BEGIN
          NEW.updated_at = CURRENT_TIMESTAMP;
          RETURN NEW;
        END;
        $update$ LANGUAGE plpgsql;

        -- Create trigger to automatically update updated_at
        DROP TRIGGER IF EXISTS update_session_updated_at ON session;
        CREATE TRIGGER update_session_updated_at
          BEFORE UPDATE ON session
          FOR EACH ROW
          EXECUTE FUNCTION update_updated_at_column();

        -- Grant permissions to sessionuser
        GRANT ALL PRIVILEGES ON TABLE session TO sessionuser;
        GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO sessionuser;
      EOF

      echo "Session database schema initialized successfully"
    '';
  };

  # Set password for sessionuser
  # This should be done separately for security, but for initial setup:
  systemd.services.set-sessionuser-password = {
    description = "Set password for sessionuser";
    after = [ "postgresql.service" ];
    before = [ "init-session-schema.service" ];
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
