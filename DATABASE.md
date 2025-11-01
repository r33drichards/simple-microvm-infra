# Session Database Documentation

## Overview

The hypervisor runs a PostgreSQL database for session management that can be accessed from all VMs.

**What's Provisioned**:
- PostgreSQL 15 server
- Database: `sessiondb`
- User: `sessionuser` with password authentication
- Network access from all VM subnets
- Automated daily backups

**Schema Initialization**: The database schema is NOT automatically initialized by NixOS. Your application is responsible for creating tables, indexes, and other schema objects.

## Connection Details

- **Host**: 10.1.0.1 (from VM1), 10.2.0.1 (from VM2), etc. (the gateway IP for each VM)
- **Port**: 5432 (default PostgreSQL port)
- **Database**: `sessiondb`
- **User**: `sessionuser`
- **Password**: `sessionpass123` (⚠️ Change this in production!)

## Schema Initialization

The NixOS configuration provisions the PostgreSQL database but does not initialize the schema. You need to create the schema manually or through your application's migration system.

### Example Schema: Session Table

Below is an example schema for a session management table. You can use this as a reference or modify it for your needs:

### Table: `session`

| Column | Type | Nullable | Description |
|--------|------|----------|-------------|
| id | UUID | NOT NULL | Primary key, auto-generated |
| messages | JSONB | NULL | JSON blob for storing messages |
| inbox_status | ENUM | NULL | Status enum: 'pending', 'processing', 'completed', 'failed' |
| sbx_config | JSONB | NULL | JSON blob for sandbox configuration |
| parent | UUID | NULL | Foreign key reference to another session (self-referential) |
| created_at | TIMESTAMP WITH TIME ZONE | NOT NULL | Automatically set on insert |
| updated_at | TIMESTAMP WITH TIME ZONE | NOT NULL | Automatically updated on modification |

### Indexes

- Primary key on `id`
- Index on `parent` for faster parent-child queries
- Index on `inbox_status` for status filtering

### Triggers

- `update_session_updated_at`: Automatically updates `updated_at` timestamp on row modification

### SQL Initialization Script

To create the example schema, connect to the database and run:

```sql
-- Create enum type for inbox-status
CREATE TYPE inbox_status_enum AS ENUM ('pending', 'processing', 'completed', 'failed');

-- Create session table
CREATE TABLE session (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  messages JSONB,
  inbox_status inbox_status_enum,
  sbx_config JSONB,
  parent UUID REFERENCES session(id),
  created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
  updated_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);

-- Create indexes
CREATE INDEX idx_session_parent ON session(parent);
CREATE INDEX idx_session_inbox_status ON session(inbox_status);

-- Create updated_at trigger function
CREATE OR REPLACE FUNCTION update_updated_at_column()
RETURNS TRIGGER AS $$
BEGIN
  NEW.updated_at = CURRENT_TIMESTAMP;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- Create trigger to automatically update updated_at
CREATE TRIGGER update_session_updated_at
  BEFORE UPDATE ON session
  FOR EACH ROW
  EXECUTE FUNCTION update_updated_at_column();
```

**To apply this schema**:

```bash
# From hypervisor
sudo -u postgres psql -d sessiondb < schema.sql

# Or interactively from a VM
psql -h 10.1.0.1 -U sessionuser -d sessiondb
# Then paste the SQL script
```

## Connection Examples

### From VM1 (PostgreSQL CLI)

```bash
# Install psql client on VM
nix-shell -p postgresql

# Connect to database
psql -h 10.1.0.1 -p 5432 -U sessionuser -d sessiondb
# Password: sessionpass123
```

### From VM (Python with psycopg2)

```python
import psycopg2
import json
from datetime import datetime

# Connect to database
conn = psycopg2.connect(
    host="10.1.0.1",  # Use appropriate gateway IP for your VM
    port=5432,
    database="sessiondb",
    user="sessionuser",
    password="sessionpass123"
)

# Create cursor
cur = conn.cursor()

# Insert a new session
cur.execute("""
    INSERT INTO session (messages, inbox_status, sbx_config)
    VALUES (%s, %s, %s)
    RETURNING id
""", (
    json.dumps({"msg": "Hello"}),
    "pending",
    json.dumps({"config": "value"})
))

session_id = cur.fetchone()[0]
print(f"Created session: {session_id}")

# Query sessions
cur.execute("SELECT * FROM session WHERE inbox_status = %s", ("pending",))
for row in cur.fetchall():
    print(row)

# Commit and close
conn.commit()
cur.close()
conn.close()
```

### From VM (Node.js with pg)

```javascript
const { Pool } = require('pg');

const pool = new Pool({
  host: '10.1.0.1',  // Use appropriate gateway IP for your VM
  port: 5432,
  database: 'sessiondb',
  user: 'sessionuser',
  password: 'sessionpass123'
});

// Insert a new session
async function createSession() {
  const result = await pool.query(
    'INSERT INTO session (messages, inbox_status, sbx_config) VALUES ($1, $2, $3) RETURNING id',
    [
      { msg: 'Hello' },
      'pending',
      { config: 'value' }
    ]
  );
  console.log('Created session:', result.rows[0].id);
}

// Query sessions
async function getSessions() {
  const result = await pool.query(
    'SELECT * FROM session WHERE inbox_status = $1',
    ['pending']
  );
  console.log('Sessions:', result.rows);
}

createSession().then(getSessions).finally(() => pool.end());
```

### From VM (Go with pgx)

```go
package main

import (
    "context"
    "encoding/json"
    "fmt"
    "github.com/jackc/pgx/v5"
)

func main() {
    // Connect to database
    conn, err := pgx.Connect(context.Background(),
        "postgres://sessionuser:sessionpass123@10.1.0.1:5432/sessiondb")
    if err != nil {
        panic(err)
    }
    defer conn.Close(context.Background())

    // Insert a new session
    var sessionID string
    messages := map[string]string{"msg": "Hello"}
    sbxConfig := map[string]string{"config": "value"}

    err = conn.QueryRow(context.Background(),
        "INSERT INTO session (messages, inbox_status, sbx_config) VALUES ($1, $2, $3) RETURNING id",
        messages, "pending", sbxConfig).Scan(&sessionID)
    if err != nil {
        panic(err)
    }
    fmt.Printf("Created session: %s\n", sessionID)

    // Query sessions
    rows, err := conn.Query(context.Background(),
        "SELECT id, messages, inbox_status FROM session WHERE inbox_status = $1",
        "pending")
    if err != nil {
        panic(err)
    }
    defer rows.Close()

    for rows.Next() {
        var id string
        var messages []byte
        var status string
        if err := rows.Scan(&id, &messages, &status); err != nil {
            panic(err)
        }
        fmt.Printf("Session %s: %s - %s\n", id, messages, status)
    }
}
```

## Network Access

The PostgreSQL database is accessible from all VM networks:

- From VM1: Connect to `10.1.0.1:5432`
- From VM2: Connect to `10.2.0.1:5432`
- From VM3: Connect to `10.3.0.1:5432`
- From VM4: Connect to `10.4.0.1:5432`
- From VM5: Connect to `10.5.0.1:5432`

The firewall on the hypervisor allows connections from all VM subnets (10.1-5.0.0/24).

## Security Notes

⚠️ **Important Security Considerations**:

1. **Change the default password**: The password `sessionpass123` is for initial setup only. Change it immediately in production.

2. **Use a secrets manager**: In production, store the password in AWS Secrets Manager or similar, not in the NixOS configuration.

3. **Network isolation**: The database is only accessible from VM networks, not from the public internet.

4. **Connection encryption**: Consider enabling SSL/TLS for PostgreSQL connections in production.

5. **Least privilege**: Create additional users with restricted permissions for different applications if needed.

## Managing the Database

### On Hypervisor

```bash
# Check PostgreSQL service status
sudo systemctl status postgresql

# View PostgreSQL logs
sudo journalctl -u postgresql -f

# Connect as postgres superuser
sudo -u postgres psql -d sessiondb

# Restart PostgreSQL
sudo systemctl restart postgresql
```

### Useful SQL Queries

```sql
-- View all sessions
SELECT * FROM session ORDER BY created_at DESC;

-- Count sessions by status
SELECT inbox_status, COUNT(*) FROM session GROUP BY inbox_status;

-- Find child sessions
SELECT * FROM session WHERE parent IS NOT NULL;

-- Find orphaned sessions (sessions with non-existent parents)
SELECT s.* FROM session s
LEFT JOIN session p ON s.parent = p.id
WHERE s.parent IS NOT NULL AND p.id IS NULL;

-- Delete old completed sessions (older than 30 days)
DELETE FROM session
WHERE inbox_status = 'completed'
AND created_at < NOW() - INTERVAL '30 days';
```

## Backup and Restore

### Automated Backups

The database is automatically backed up daily using the NixOS PostgreSQL backup service:

- **Schedule**: Daily at 2:00 AM
- **Location**: `/var/backup/postgresql/`
- **Database**: `sessiondb`
- **Compression**: zstd (level 9) for optimal compression
- **Format**: SQL dump with CREATE DATABASE commands

**Check backup status**:
```bash
# View backup service status
sudo systemctl status postgresqlBackup-sessiondb.service

# View backup timer status
sudo systemctl status postgresqlBackup-sessiondb.timer

# List recent backup logs
sudo journalctl -u postgresqlBackup-sessiondb.service -n 50

# View backup files
sudo ls -lh /var/backup/postgresql/
```

**Manually trigger a backup**:
```bash
# Run backup immediately
sudo systemctl start postgresqlBackup-sessiondb.service

# Check result
sudo journalctl -u postgresqlBackup-sessiondb.service -f
```

### Backup Files

Backup files are named: `sessiondb.sql.zst`

The backup service creates a single file that is overwritten on each run. For retention of multiple backups, consider:

1. **Copy backups before they're overwritten**:
```bash
# Daily cron job to archive backups
sudo cp /var/backup/postgresql/sessiondb.sql.zst \
  /var/backup/postgresql/archive/sessiondb_$(date +%Y%m%d).sql.zst
```

2. **Upload to S3** (recommended for production):
```bash
# Add to systemd timer or cron
sudo aws s3 cp /var/backup/postgresql/sessiondb.sql.zst \
  s3://my-backups/postgresql/sessiondb_$(date +%Y%m%d).sql.zst
```

### Manual Backup

If you need an immediate backup outside the automated schedule:

```bash
# Manual backup (uncompressed)
sudo -u postgres pg_dump sessiondb > sessiondb_backup_$(date +%Y%m%d).sql

# Manual backup with gzip compression
sudo -u postgres pg_dump sessiondb | gzip > sessiondb_backup_$(date +%Y%m%d).sql.gz

# Manual backup with zstd compression (better compression)
sudo -u postgres pg_dump sessiondb | zstd -9 > sessiondb_backup_$(date +%Y%m%d).sql.zst
```

### Restore

**From automated backup**:
```bash
# Decompress and restore
sudo zstd -d /var/backup/postgresql/sessiondb.sql.zst -c | sudo -u postgres psql sessiondb
```

**From manual backup**:
```bash
# Restore from uncompressed SQL
sudo -u postgres psql sessiondb < sessiondb_backup_20231101.sql

# Restore from gzip
zcat sessiondb_backup_20231101.sql.gz | sudo -u postgres psql sessiondb

# Restore from zstd
zstdcat sessiondb_backup_20231101.sql.zst | sudo -u postgres psql sessiondb
```

**Full restore (drop and recreate database)**:
```bash
# Drop existing database (WARNING: destroys all data!)
sudo -u postgres psql -c "DROP DATABASE IF EXISTS sessiondb;"
sudo -u postgres psql -c "CREATE DATABASE sessiondb;"

# Restore from backup
sudo zstd -d /var/backup/postgresql/sessiondb.sql.zst -c | sudo -u postgres psql sessiondb

# Verify restoration
sudo -u postgres psql -d sessiondb -c "SELECT COUNT(*) FROM session;"
```

### Backup Retention Strategy

For production use, implement a retention policy:

**Example: Keep daily backups for 7 days, weekly for 4 weeks**:
```bash
#!/bin/bash
# /usr/local/bin/backup-retention.sh

BACKUP_DIR="/var/backup/postgresql/archive"
S3_BUCKET="s3://my-backups/postgresql"

# Archive current backup
DATE=$(date +%Y%m%d)
cp /var/backup/postgresql/sessiondb.sql.zst "$BACKUP_DIR/sessiondb_$DATE.sql.zst"

# Upload to S3
aws s3 cp "$BACKUP_DIR/sessiondb_$DATE.sql.zst" "$S3_BUCKET/"

# Delete local backups older than 7 days
find "$BACKUP_DIR" -name "sessiondb_*.sql.zst" -mtime +7 -delete

# Delete S3 backups older than 30 days (requires AWS CLI)
# Add lifecycle policy in S3 console or use aws s3api
```

Add to systemd timer or cron for automatic execution.

## Monitoring

### Check database size

```sql
SELECT pg_size_pretty(pg_database_size('sessiondb'));
```

### Check table size

```sql
SELECT pg_size_pretty(pg_total_relation_size('session'));
```

### Check active connections

```sql
SELECT count(*) FROM pg_stat_activity WHERE datname = 'sessiondb';
```

### View slow queries

```sql
SELECT pid, now() - pg_stat_activity.query_start AS duration, query
FROM pg_stat_activity
WHERE state = 'active' AND now() - pg_stat_activity.query_start > interval '5 seconds';
```

## Troubleshooting

### Can't connect from VM

1. Check if PostgreSQL is running on hypervisor:
   ```bash
   sudo systemctl status postgresql
   ```

2. Check if firewall allows connections:
   ```bash
   sudo iptables -L -n | grep 5432
   ```

3. Check if VM can reach hypervisor gateway:
   ```bash
   ping 10.1.0.1  # Use your VM's gateway IP
   ```

4. Check PostgreSQL logs:
   ```bash
   sudo journalctl -u postgresql -f
   ```

### Password authentication fails

Verify the password is set correctly:

```bash
# On hypervisor as postgres user
sudo -u postgres psql -c "ALTER USER sessionuser WITH PASSWORD 'sessionpass123';"
```

### Backups not running

If automated backups aren't working:

```bash
# Check if backup timer is active
sudo systemctl status postgresqlBackup-sessiondb.timer

# Check if backup timer is enabled
sudo systemctl list-timers | grep postgresql

# View backup service logs
sudo journalctl -u postgresqlBackup-sessiondb.service

# Manually trigger backup to test
sudo systemctl start postgresqlBackup-sessiondb.service

# Check backup directory exists and has proper permissions
sudo ls -ld /var/backup/postgresql/
# Should show: drwxr-xr-x postgres postgres
```

### Restore fails

If restore fails:

```bash
# Check if database exists
sudo -u postgres psql -l | grep sessiondb

# Check if user has permissions
sudo -u postgres psql -d sessiondb -c "\du sessionuser"

# Try restoring with verbose error output
sudo zstd -d /var/backup/postgresql/sessiondb.sql.zst -c | sudo -u postgres psql -d sessiondb -v ON_ERROR_STOP=1

# If schema conflicts, drop and recreate database first
sudo -u postgres psql -c "DROP DATABASE IF EXISTS sessiondb;"
sudo -u postgres psql -c "CREATE DATABASE sessiondb OWNER sessionuser;"
```
