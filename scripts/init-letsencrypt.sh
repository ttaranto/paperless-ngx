#!/bin/bash
# init-letsencrypt.sh
# Initialize Let's Encrypt SSL certificates for Paperless-ngx
# Mirrors the Kurumin Agua webroot + temp Nginx config flow

set -e

# Load environment variables
if [ -f ../.env ]; then
    source ../.env
elif [ -f .env ]; then
    source .env
fi

# Paths
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
NGINX_TEMPLATE="$PROJECT_DIR/nginx/conf.d/paperless.conf"
NGINX_SITE_NAME="paperless"
NGINX_AVAILABLE="/etc/nginx/sites-available/$NGINX_SITE_NAME"
NGINX_ENABLED="/etc/nginx/sites-enabled/$NGINX_SITE_NAME"
NGINX_TEMP="/etc/nginx/sites-available/${NGINX_SITE_NAME}-temp"

# Configuration
DOMAIN="${SSL_DOMAIN:-}"
if [ -z "$DOMAIN" ] && [ -n "$PAPERLESS_URL" ]; then
    DOMAIN="${PAPERLESS_URL#http://}"
    DOMAIN="${DOMAIN#https://}"
    DOMAIN="${DOMAIN%%/*}"
fi
DOMAIN="${DOMAIN:-paperless.taranto.ai}"

EMAIL="${SSL_EMAIL:-${PAPERLESS_ADMIN_MAIL:-admin@$DOMAIN}}"
STAGING="${SSL_STAGING:-0}"
APP_PORT="${PAPERLESS_PORT:-8085}"

echo "==================================================="
echo "Paperless-ngx Let's Encrypt Certificate Setup"
echo "==================================================="
echo "Domain: $DOMAIN"
echo "Email: $EMAIL"
echo "Staging: $STAGING"
echo "App Port: $APP_PORT"
echo "Project Directory: $PROJECT_DIR"
echo "==================================================="

if [ "$EUID" -ne 0 ]; then
    echo "Please run this script with sudo or as root."
    exit 1
fi

if ! command -v nginx >/dev/null 2>&1; then
    echo "nginx not found. Install it before running this script."
    exit 1
fi

if ! command -v certbot >/dev/null 2>&1; then
    echo "certbot not found. Install it before running this script."
    exit 1
fi

if [ ! -f "$NGINX_TEMPLATE" ]; then
    echo "Nginx template not found at $NGINX_TEMPLATE"
    exit 1
fi

# Staging flag
if [ "$STAGING" = "1" ]; then
    echo "Using Let's Encrypt STAGING server (certificates won't be valid)"
    STAGING_ARG="--staging"
else
    STAGING_ARG=""
fi

echo ""
echo "Creating directories..."
mkdir -p /var/www/certbot

echo ""
echo "Configuring Nginx template..."
cp "$NGINX_TEMPLATE" "$NGINX_AVAILABLE"
sed -i "s/DOMAIN_NAME/$DOMAIN/g" "$NGINX_AVAILABLE"
sed -i "s/APP_PORT/$APP_PORT/g" "$NGINX_AVAILABLE"

echo ""
echo "Creating temporary Nginx config for ACME challenge..."
cat > "$NGINX_TEMP" << EOF
server {
    listen 80;
    server_name $DOMAIN;

    location /.well-known/acme-challenge/ {
        root /var/www/certbot;
    }

    location / {
        return 200 'Server is being configured...';
        add_header Content-Type text/plain;
    }
}
EOF

ln -sf "$NGINX_TEMP" "$NGINX_ENABLED"
rm -f /etc/nginx/sites-enabled/default

echo "Testing nginx configuration..."
nginx -t && systemctl restart nginx

echo ""
echo "Obtaining SSL certificate..."
echo "Make sure your domain ($DOMAIN) points to this server's IP."
echo ""
read -p "Press Enter when DNS is configured, or Ctrl+C to abort..."

certbot certonly --webroot -w /var/www/certbot \
    -d "$DOMAIN" \
    $STAGING_ARG \
    --non-interactive \
    --agree-tos \
    --email "$EMAIL" || {
    echo "Failed to obtain SSL certificate."
    echo "Make sure:"
    echo "  1. Domain $DOMAIN points to this server's IP"
    echo "  2. Port 80 is accessible from the internet"
    echo ""
    echo "You can retry SSL setup later with:"
    echo "  certbot certonly --webroot -w /var/www/certbot -d $DOMAIN"
    echo ""
    echo "Continuing without SSL for now..."
}

if [ -f "/etc/letsencrypt/live/$DOMAIN/fullchain.pem" ]; then
    ln -sf "$NGINX_AVAILABLE" "$NGINX_ENABLED"
    rm -f "$NGINX_TEMP"
    nginx -t && systemctl restart nginx
    echo "SSL certificate installed successfully"

    echo "0 0,12 * * * root certbot renew --quiet" > /etc/cron.d/certbot-renew
    echo "SSL auto-renewal configured"
else
    echo "Running without SSL. Configure it later."
fi

echo ""
echo "==================================================="
echo "Setup complete!"
echo "==================================================="
echo ""
echo "Your Paperless-ngx instance should now be accessible at:"
echo "https://$DOMAIN"
echo ""
