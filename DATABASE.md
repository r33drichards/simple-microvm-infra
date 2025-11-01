# Session Database Documentation

## Overview

The hypervisor runs a PostgreSQL database for session management that can be accessed from all VMs.

## Connection Details

- **Host**: 10.1.0.1 (from VM1), 10.2.0.1 (from VM2), etc. (the gateway IP for each VM)
- **Port**: 5432 (default PostgreSQL port)
- **Database**: `sessiondb`
- **User**: `sessionuser`
- **Password**: `sessionpass123` (⚠️ Change this in production!)

## Schema

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

### Backup

```bash
# On hypervisor
sudo -u postgres pg_dump sessiondb > sessiondb_backup_$(date +%Y%m%d).sql

# Backup to S3
sudo -u postgres pg_dump sessiondb | gzip | aws s3 cp - s3://my-backups/sessiondb_$(date +%Y%m%d).sql.gz
```

### Restore

```bash
# On hypervisor
sudo -u postgres psql sessiondb < sessiondb_backup_20231101.sql
```

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

### Schema not initialized

If the schema isn't created automatically, check the init service:

```bash
# Check service status
sudo systemctl status init-session-schema

# View logs
sudo journalctl -u init-session-schema

# Manually run initialization
sudo systemctl start init-session-schema
```

### Password authentication fails

Verify the password is set correctly:

```bash
# On hypervisor as postgres user
sudo -u postgres psql -c "ALTER USER sessionuser WITH PASSWORD 'sessionpass123';"
```
