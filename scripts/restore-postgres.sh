#!/bin/bash
# restore-postgres.sh
# Restore PostgreSQL database from backup for Paperless-ngx
#
# Usage: ./restore-postgres.sh <backup_file>
#        ./restore-postgres.sh latest
#
# WARNING: This will REPLACE all data in the database!

set -e

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
BACKUP_DIR="$PROJECT_DIR/backups"
CONTAINER_NAME="paperless-postgres"
PAPERLESS_CONTAINER="paperless-app"

# Load environment variables
if [ -f "$PROJECT_DIR/.env" ]; then
    source "$PROJECT_DIR/.env"
fi

# Database credentials from environment
DB_NAME="${POSTGRES_DB:-paperless}"
DB_USER="${POSTGRES_USER:-paperless}"

# Check arguments
if [ -z "$1" ]; then
    echo "Usage: $0 <backup_file|latest>"
    echo ""
    echo "Available backups:"
    ls -lh "$BACKUP_DIR"/paperless_*.sql.gz 2>/dev/null || echo "No backups found in $BACKUP_DIR"
    exit 1
fi

# Determine backup file
if [ "$1" = "latest" ]; then
    BACKUP_FILE="$BACKUP_DIR/latest.sql.gz"
    if [ ! -L "$BACKUP_FILE" ]; then
        echo "ERROR: No 'latest' symlink found. Please specify a backup file."
        exit 1
    fi
    # Resolve symlink to actual file
    BACKUP_FILE=$(readlink -f "$BACKUP_FILE")
else
    BACKUP_FILE="$1"
fi

# Verify backup file exists
if [ ! -f "$BACKUP_FILE" ]; then
    echo "ERROR: Backup file not found: $BACKUP_FILE"
    exit 1
fi

BACKUP_SIZE=$(du -h "$BACKUP_FILE" | cut -f1)
BACKUP_DATE=$(stat -c %y "$BACKUP_FILE" | cut -d' ' -f1,2 | cut -d'.' -f1)

echo "==================================================="
echo "Paperless-ngx PostgreSQL Restore"
echo "==================================================="
echo "Backup file: $BACKUP_FILE"
echo "Backup size: $BACKUP_SIZE"
echo "Backup date: $BACKUP_DATE"
echo "Target database: $DB_NAME"
echo "==================================================="
echo ""
echo "WARNING: This will REPLACE ALL DATA in the database!"
echo "Make sure you have a current backup before proceeding."
echo ""
read -p "Are you sure you want to restore? [y/N] " -n 1 -r
echo

if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "Restore cancelled."
    exit 0
fi

# Check if postgres container is running
if ! docker ps --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
    echo "ERROR: PostgreSQL container '$CONTAINER_NAME' is not running!"
    echo "Start the containers with: docker compose up -d postgres"
    exit 1
fi

# Stop paperless to prevent conflicts
echo ""
echo "Stopping Paperless application..."
docker compose -f "$PROJECT_DIR/docker-compose.yml" stop paperless 2>/dev/null || true

# Wait for connections to close
sleep 3

# Drop existing connections and recreate database
echo ""
echo "Preparing database..."
docker exec "$CONTAINER_NAME" psql -U "$DB_USER" -d postgres -c "
    SELECT pg_terminate_backend(pg_stat_activity.pid)
    FROM pg_stat_activity
    WHERE pg_stat_activity.datname = '$DB_NAME'
    AND pid <> pg_backend_pid();" 2>/dev/null || true

docker exec "$CONTAINER_NAME" psql -U "$DB_USER" -d postgres -c "DROP DATABASE IF EXISTS $DB_NAME;"
docker exec "$CONTAINER_NAME" psql -U "$DB_USER" -d postgres -c "CREATE DATABASE $DB_NAME OWNER $DB_USER;"

# Restore backup
echo ""
echo "Restoring database from backup..."
echo "This may take a while depending on the backup size..."

gunzip -c "$BACKUP_FILE" | docker exec -i "$CONTAINER_NAME" psql -U "$DB_USER" -d "$DB_NAME" --quiet

# Verify restore
echo ""
echo "Verifying restore..."
TABLE_COUNT=$(docker exec "$CONTAINER_NAME" psql -U "$DB_USER" -d "$DB_NAME" -t -c "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema = 'public';")
TABLE_COUNT=$(echo "$TABLE_COUNT" | tr -d ' ')

if [ "$TABLE_COUNT" -gt 0 ]; then
    echo "Database restored successfully!"
    echo "Tables restored: $TABLE_COUNT"
else
    echo "WARNING: Database appears empty after restore!"
fi

# Restart paperless
echo ""
echo "Starting Paperless application..."
docker compose -f "$PROJECT_DIR/docker-compose.yml" up -d paperless

# Wait for paperless to be healthy
echo "Waiting for Paperless to start..."
sleep 10

# Check paperless status
if docker ps --format '{{.Names}}' | grep -q "^${PAPERLESS_CONTAINER}$"; then
    echo "Paperless is running."
else
    echo "WARNING: Paperless container may not have started properly."
    echo "Check logs with: docker compose logs paperless"
fi

echo ""
echo "==================================================="
echo "Restore Complete"
echo "==================================================="
echo "Restored from: $BACKUP_FILE"
echo "Completed: $(date)"
echo "==================================================="
echo ""
echo "Please verify your data at: https://paperless.taranto.ai"
