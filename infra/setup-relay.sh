#!/usr/bin/env bash
# Run as root on the dedicated Ubuntu relay, normally via configure-relay.sh.
set -euo pipefail
[[ $EUID -eq 0 && $# -eq 3 ]] || { printf 'Usage (root): setup-relay.sh IP FIRST_PORT LAST_PORT\n' >&2; exit 1; }
relay_ip=$1
first_port=$2
last_port=$3
[[ "$relay_ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || exit 1
IFS=. read -r -a octets <<< "$relay_ip"
for octet in "${octets[@]}"; do [[ $((10#$octet)) -le 255 ]] || exit 1; done
[[ "$first_port" =~ ^2[0-9]{4}$ && "$last_port" =~ ^2[0-9]{4}$ && "$last_port" -ge "$first_port" ]] || exit 1
exec 9>/run/mac-egress-relay-setup.lock
flock -n 9 || { printf 'Another relay setup is running.\n' >&2; exit 1; }

# A later tenant manager will replace this empty-relay configuration. Never
# silently overwrite active tenant routes when re-running the foundation setup.
if [[ -e /var/lib/mac-egress-relay/tenants-enrolled ]]; then
  printf 'Tenants are enrolled; use the tenant-aware configuration workflow.\n' >&2
  exit 1
fi

export DEBIAN_FRONTEND=noninteractive
apt-get -o DPkg::Lock::Timeout=120 update
apt-get -o DPkg::Lock::Timeout=120 install -y haproxy snapd ca-certificates curl
if ! snap list certbot >/dev/null 2>&1; then
  snap install --classic certbot
fi
/snap/bin/certbot --version
/snap/bin/certbot --help all | grep -- --ip-address >/dev/null

install -d -m 700 /etc/haproxy/certs
install -d -m 755 /etc/letsencrypt/renewal-hooks/deploy /var/lib/mac-egress-relay

# This hook also runs after unattended renewal. Stage the PEM, validate it with
# HAProxy, then atomically replace the live file and reload without dropping TLS.
cat > /etc/letsencrypt/renewal-hooks/deploy/relay <<'HOOK'
#!/usr/bin/env bash
set -euo pipefail
[[ "${RENEWED_LINEAGE:-}" == /etc/letsencrypt/live/relay ]] || exit 0
umask 077
candidate=$(mktemp /etc/haproxy/certs/relay.XXXXXX)
check_config=$(mktemp /etc/haproxy/relay-check.XXXXXX)
trap 'rm -f "$candidate" "$check_config"' EXIT
cat "$RENEWED_LINEAGE/fullchain.pem" "$RENEWED_LINEAGE/privkey.pem" > "$candidate"
sed "s|/etc/haproxy/certs/relay.pem|$candidate|g" /etc/haproxy/haproxy.cfg > "$check_config"
haproxy -c -f "$check_config"
mv -f "$candidate" /etc/haproxy/certs/relay.pem
systemctl reload-or-restart haproxy
HOOK
chmod 700 /etc/letsencrypt/renewal-hooks/deploy/relay

cat > /etc/haproxy/haproxy.cfg <<CONFIG
global
    user haproxy
    group haproxy
    daemon
    maxconn 256
    ssl-default-bind-options ssl-min-ver TLSv1.2

defaults
    mode http
    timeout connect 5s
    timeout client 30s
    timeout server 30s
    timeout http-request 10s

# No forwarding exists until tenant enrollment. Every request, including
# CONNECT, receives a deliberate 503 after a verified TLS handshake.
frontend unenrolled
    bind 0.0.0.0:$first_port-$last_port ssl crt /etc/haproxy/certs/relay.pem alpn http/1.1
    maxconn 32
    http-request return status 503 content-type text/plain string "No tenant enrolled."
CONFIG

# IP certificates need a current ACME client. Use standalone HTTP-01 on port 80;
# tenant TLS ports remain independent. Account creation intentionally uses no
# contact email, keeping deployment free of user-specific registration settings.
/snap/bin/certbot certonly --standalone --non-interactive --agree-tos \
  --register-unsafely-without-email --preferred-profile shortlived \
  --ip-address "$relay_ip" --cert-name relay --keep-until-expiring
RENEWED_LINEAGE=/etc/letsencrypt/live/relay /etc/letsencrypt/renewal-hooks/deploy/relay

systemctl enable haproxy
# The official Certbot snap installs its own automatic renewal timer.
systemctl enable --now snap.certbot.renew.timer

# Local health check with a nonzero exit status for a stopped TLS service,
# incorrect response, certificate expiring within 24h, or disabled renewal timer.
cat > /usr/local/sbin/relay-health <<HEALTH
#!/usr/bin/env bash
set -euo pipefail
systemctl is-active --quiet haproxy
systemctl is-active --quiet snap.certbot.renew.timer
openssl x509 -in /etc/letsencrypt/live/relay/cert.pem -checkend 86400 -noout
status=\$(curl --silent --show-error --max-time 10 --noproxy '*' \\
  --connect-to '$relay_ip:$first_port:127.0.0.1:$first_port' \\
  --output /dev/null --write-out '%{http_code}' 'https://$relay_ip:$first_port/')
[[ "\$status" == 503 ]]
printf 'Relay TLS healthy; no tenants enrolled.\\n'
HEALTH
chmod 755 /usr/local/sbin/relay-health
cat > /etc/systemd/system/relay-health.service <<'UNIT'
[Unit]
Description=Check relay TLS and certificate renewal readiness
After=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/relay-health
UNIT
cat > /etc/systemd/system/relay-health.timer <<'UNIT'
[Unit]
Description=Check relay TLS every hour

[Timer]
OnBootSec=5min
OnUnitActiveSec=1h

[Install]
WantedBy=timers.target
UNIT
systemctl daemon-reload
systemctl enable --now relay-health.timer
systemctl start relay-health.service
printf 'Relay configured at https://%s:%s (no tenants enrolled).\n' "$relay_ip" "$first_port"
