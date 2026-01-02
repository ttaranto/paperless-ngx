#!/bin/bash
# init-letsencrypt.sh
# Initialize Let's Encrypt SSL certificates for Paperless-ngx
# Based on: https://github.com/wmnnd/nginx-certbot

set -e

# Load environment variables
if [ -f ../.env ]; then
    source ../.env
elif [ -f .env ]; then
    source .env
fi

# Configuration
DOMAIN="${SSL_DOMAIN:-paperless.taranto.ai}"
EMAIL="${SSL_EMAIL:-}"
STAGING="${SSL_STAGING:-0}"
RSA_KEY_SIZE=4096

# Paths
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
CERTBOT_PATH="$PROJECT_DIR/certbot"

echo "==================================================="
echo "Paperless-ngx Let's Encrypt Certificate Setup"
echo "==================================================="
echo "Domain: $DOMAIN"
echo "Email: ${EMAIL:-'(not set - will use --register-unsafely-without-email)'}"
echo "Staging: $STAGING"
echo "Project Directory: $PROJECT_DIR"
echo "==================================================="

# Check if email is set
if [ -z "$EMAIL" ]; then
    echo ""
    echo "WARNING: No email set. Certificate expiry notifications won't be sent."
    echo "Set SSL_EMAIL in your .env file to receive notifications."
    echo ""
    read -p "Continue without email? [y/N] " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        exit 1
    fi
    EMAIL_ARG="--register-unsafely-without-email"
else
    EMAIL_ARG="--email $EMAIL"
fi

# Staging flag
if [ "$STAGING" = "1" ]; then
    echo "Using Let's Encrypt STAGING server (certificates won't be valid)"
    STAGING_ARG="--staging"
else
    STAGING_ARG=""
fi

# Create required directories
echo ""
echo "Creating directories..."
mkdir -p "$CERTBOT_PATH/conf"
mkdir -p "$CERTBOT_PATH/www"

# Download recommended TLS parameters
if [ ! -f "$CERTBOT_PATH/conf/options-ssl-nginx.conf" ]; then
    echo "Downloading recommended SSL parameters..."
    curl -s https://raw.githubusercontent.com/certbot/certbot/master/certbot-nginx/certbot_nginx/_internal/tls_configs/options-ssl-nginx.conf > "$CERTBOT_PATH/conf/options-ssl-nginx.conf"
fi

if [ ! -f "$CERTBOT_PATH/conf/ssl-dhparams.pem" ]; then
    echo "Downloading DH parameters..."
    curl -s https://raw.githubusercontent.com/certbot/certbot/master/certbot/certbot/ssl-dhparams.pem > "$CERTBOT_PATH/conf/ssl-dhparams.pem"
fi

# Check if certificates already exist
if [ -d "$CERTBOT_PATH/conf/live/$DOMAIN" ]; then
    echo ""
    echo "Existing certificates found for $DOMAIN"
    read -p "Replace existing certificates? [y/N] " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo "Keeping existing certificates."
        exit 0
    fi
fi

# Create dummy certificate for nginx to start
echo ""
echo "Creating dummy certificate for nginx..."
CERT_PATH="$CERTBOT_PATH/conf/live/$DOMAIN"
mkdir -p "$CERT_PATH"

docker compose -f "$PROJECT_DIR/docker-compose.yml" run --rm --entrypoint "\
    openssl req -x509 -nodes -newkey rsa:$RSA_KEY_SIZE -days 1 \
    -keyout '/etc/letsencrypt/live/$DOMAIN/privkey.pem' \
    -out '/etc/letsencrypt/live/$DOMAIN/fullchain.pem' \
    -subj '/CN=localhost'" certbot

# Create chain.pem (copy of fullchain for OCSP)
cp "$CERT_PATH/fullchain.pem" "$CERT_PATH/chain.pem" 2>/dev/null || true

# Start nginx
echo ""
echo "Starting nginx..."
docker compose -f "$PROJECT_DIR/docker-compose.yml" up -d nginx

# Wait for nginx to be ready
echo "Waiting for nginx to start..."
sleep 5

# Delete dummy certificate
echo ""
echo "Deleting dummy certificate..."
docker compose -f "$PROJECT_DIR/docker-compose.yml" run --rm --entrypoint "\
    rm -rf /etc/letsencrypt/live/$DOMAIN && \
    rm -rf /etc/letsencrypt/archive/$DOMAIN && \
    rm -rf /etc/letsencrypt/renewal/$DOMAIN.conf" certbot

# Request real certificate
echo ""
echo "Requesting Let's Encrypt certificate..."
docker compose -f "$PROJECT_DIR/docker-compose.yml" run --rm --entrypoint "\
    certbot certonly --webroot -w /var/www/certbot \
    $STAGING_ARG \
    $EMAIL_ARG \
    -d $DOMAIN \
    --rsa-key-size $RSA_KEY_SIZE \
    --agree-tos \
    --force-renewal" certbot

# Reload nginx with real certificate
echo ""
echo "Reloading nginx with valid certificate..."
docker compose -f "$PROJECT_DIR/docker-compose.yml" exec nginx nginx -s reload

echo ""
echo "==================================================="
echo "SSL certificate successfully obtained!"
echo "==================================================="
echo ""
echo "Your Paperless-ngx instance should now be accessible at:"
echo "https://$DOMAIN"
echo ""
echo "Certificate will auto-renew via the certbot container."
echo ""
