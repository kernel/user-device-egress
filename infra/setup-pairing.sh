#!/usr/bin/env bash
# Run through pairing.sh install after deploying the current CloudFormation template.
set -euo pipefail
id relaypair >/dev/null 2>&1 || useradd --system --no-create-home --shell /usr/sbin/nologin relaypair
install -o root -g root -m 0755 /var/lib/mac-egress-relay/pairing-upload/server /usr/local/bin/relay-pairing
install -o root -g root -m 0700 /var/lib/mac-egress-relay/pairing-upload/manager /usr/local/sbin/relay-pair
install -o root -g root -m 0700 /var/lib/mac-egress-relay/pairing-upload/tenant /usr/local/sbin/relay-tenant
printf '%s\n' 'relaypair ALL=(root) NOPASSWD: /usr/local/sbin/relay-pair redeem' > /etc/sudoers.d/relay-pairing
chmod 0440 /etc/sudoers.d/relay-pairing
visudo -cf /etc/sudoers.d/relay-pairing
cat > /etc/systemd/system/relay-pairing.service <<'UNIT'
[Unit]
Description=Single-use relay pairing API
After=network-online.target

[Service]
User=relaypair
Group=relaypair
ExecStart=/usr/local/bin/relay-pairing
Restart=on-failure
RestartSec=3
PrivateTmp=true
ProtectHome=true
MemoryMax=128M
TasksMax=32
UMask=0077

[Install]
WantedBy=multi-user.target
UNIT
systemctl daemon-reload
systemctl enable --now relay-pairing
systemctl restart relay-pairing
touch /var/lib/mac-egress-relay/pairing-enabled
# Re-render under the same lock as enrollment, preserving tenants and port ranges.
read -r ip first last < <(python3 -c 'import json; s=json.load(open("/var/lib/mac-egress-relay/settings.json")); print(s["ip"],s["first"],s["last"])')
/usr/local/sbin/relay-tenant init "$ip" "$first" "$last"
