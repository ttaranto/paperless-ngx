#!/bin/bash
# backup-postgres.sh
# Automated PostgreSQL backup script for Paperless-ngx
#
# Usage: ./backup-postgres.sh [backup_dir]
#
# Cron example (daily at 2 AM):
# 0 2 * * * /path/to/scripts/backup-postgres.sh >> /var/log/paperless-backup.log 2>&1

set -e

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
BACKUP_DIR="${1:-$PROJECT_DIR/backups}"
RETENTION_DAYS=30
TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
CONTAINER_NAME="paperless-postgres"

# Load environment variables
if [ -f "$PROJECT_DIR/.env" ]; then
    source "$PROJECT_DIR/.env"
fi

# Database credentials from environment
DB_NAME="${POSTGRES_DB:-paperless}"
DB_USER="${POSTGRES_USER:-paperless}"

# Backup filename
BACKUP_FILE="$BACKUP_DIR/paperless_${TIMESTAMP}.sql.gz"

echo "==================================================="
echo "Paperless-ngx PostgreSQL Backup"
echo "==================================================="
echo "Timestamp: $(date)"
echo "Database: $DB_NAME"
echo "Backup Directory: $BACKUP_DIR"
echo "Retention: $RETENTION_DAYS days"
echo "==================================================="

# Create backup directory if it doesn't exist
mkdir -p "$BACKUP_DIR"

# Check if container is running
if ! docker ps --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
    echo "ERROR: PostgreSQL container '$CONTAINER_NAME' is not running!"
    exit 1
fi

# Create backup
echo ""
echo "Creating database backup..."
docker exec "$CONTAINER_NAME" pg_dump -U "$DB_USER" -d "$DB_NAME" --format=plain | gzip > "$BACKUP_FILE"

# Verify backup
if [ -f "$BACKUP_FILE" ] && [ -s "$BACKUP_FILE" ]; then
    BACKUP_SIZE=$(du -h "$BACKUP_FILE" | cut -f1)
    echo "Backup created successfully: $BACKUP_FILE ($BACKUP_SIZE)"
else
    echo "ERROR: Backup file is empty or was not created!"
    rm -f "$BACKUP_FILE"
    exit 1
fi

# Create latest symlink
LATEST_LINK="$BACKUP_DIR/latest.sql.gz"
ln -sf "$BACKUP_FILE" "$LATEST_LINK"
echo "Updated latest symlink: $LATEST_LINK"

# Rotate old backups
echo ""
echo "Removing backups older than $RETENTION_DAYS days..."
DELETED_COUNT=$(find "$BACKUP_DIR" -name "paperless_*.sql.gz" -type f -mtime +$RETENTION_DAYS -delete -print | wc -l)
echo "Deleted $DELETED_COUNT old backup(s)"

# List current backups
echo ""
echo "Current backups:"
ls -lh "$BACKUP_DIR"/paperless_*.sql.gz 2>/dev/null | tail -10

# Calculate total backup size
TOTAL_SIZE=$(du -sh "$BACKUP_DIR" | cut -f1)
BACKUP_COUNT=$(find "$BACKUP_DIR" -name "paperless_*.sql.gz" -type f | wc -l)

echo ""
echo "==================================================="
echo "Backup Summary"
echo "==================================================="
echo "Total backups: $BACKUP_COUNT"
echo "Total size: $TOTAL_SIZE"
echo "Latest backup: $BACKUP_FILE"
echo "Completed: $(date)"
echo "==================================================="
