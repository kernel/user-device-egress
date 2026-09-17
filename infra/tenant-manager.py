#!/usr/bin/env python3
"""Root-only, operator-driven enrollment on a dedicated relay VM."""
import fcntl
import json
import os
from pathlib import Path
import re
import secrets
import subprocess
import sys
import tempfile

STATE = Path('/var/lib/mac-egress-relay')
CONFIG = Path('/etc/mac-egress-relay')


def run(*args):
    subprocess.run(args, check=True, stdout=sys.stderr)


def write(path, text, mode=0o600):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, name = tempfile.mkstemp(dir=path.parent)
    try:
        with os.fdopen(fd, 'w') as stream:
            stream.write(text)
        os.chmod(name, mode)
        os.replace(name, path)
    finally:
        if os.path.exists(name):
            os.unlink(name)


def render(settings, tenants):
    cfg = '''global
    user haproxy
    group haproxy
    daemon
    maxconn 256
    ssl-default-bind-options ssl-min-ver TLSv1.2

defaults
    mode tcp
    timeout connect 5s
    timeout client 5m
    timeout server 5m

frontend health
    mode http
    bind 127.0.0.1:19999 ssl crt /etc/haproxy/certs/relay.pem
    http-request return status 200 content-type text/plain string "Relay healthy."
'''
    active = {t['port']: t for t in tenants.values() if t['active']}
    if (STATE / 'pairing-enabled').exists():
        cfg += '''
listen pairing
    mode http
    bind 0.0.0.0:443 ssl crt /etc/haproxy/certs/relay.pem alpn http/1.1
    maxconn 32
    timeout http-request 5s
    timeout client 55s
    timeout server 55s
    stick-table type ip size 10k expire 1m store http_req_rate(1m)
    http-request track-sc0 src
    http-request deny deny_status 429 if { sc_http_req_rate(0) gt 30 }
    http-request deny deny_status 404 unless METH_POST
    http-request deny deny_status 404 unless { path -m str /v1/pair }
    server pairing 127.0.0.1:19998
'''
    for port in range(settings['first'], settings['last'] + 1):
        cfg += f'\nlisten port_{port}\n'
        if port not in active:
            cfg += '    mode http\n'
        cfg += f'    bind 0.0.0.0:{port} ssl crt /etc/haproxy/certs/relay.pem alpn http/1.1\n    maxconn 32\n'
        if port in active:
            cfg += f'    server mac 127.0.0.1:{port + 10000}\n'
        else:
            cfg += '    http-request return status 503 content-type text/plain string "No tenant enrolled."\n'
    candidate = CONFIG / 'haproxy.candidate'
    write(candidate, cfg)
    run('haproxy', '-c', '-f', str(candidate))
    os.replace(candidate, '/etc/haproxy/haproxy.cfg')
    run('systemctl', 'reload', 'haproxy')


def initialize(ip, first, last):
    import ipaddress
    ipaddress.IPv4Address(ip)
    if not 20000 <= first <= last <= 29999:
        raise ValueError('Invalid port range')
    settings = dict(ip=ip, first=first, last=last)
    if (STATE / 'settings.json').exists():
        previous = json.loads((STATE / 'settings.json').read_text())
        if previous['ip'] != ip or previous['first'] != first or last < previous['last']:
            raise ValueError('Only extending the port range is supported; other changes need a migration')
    CONFIG.mkdir(mode=0o755, exist_ok=True)
    CONFIG.chmod(0o755)
    (CONFIG / 'tenants').mkdir(mode=0o755, exist_ok=True)
    (CONFIG / 'tenants').chmod(0o755)
    write('/etc/systemd/system/relay-tunnel@.service', '''[Unit]
Description=Restricted SSH tunnel for relay tenant %i
After=network-online.target

[Service]
ExecStart=/usr/sbin/sshd -D -e -f /etc/mac-egress-relay/tenants/%i/sshd_config
KillMode=control-group
Restart=on-failure
RestartSec=3
TasksMax=64
MemoryMax=128M
TimeoutStopSec=5

[Install]
WantedBy=multi-user.target
''', 0o644)
    write(STATE / 'settings.json', json.dumps(settings))
    if not (STATE / 'tenants.json').exists():
        write(STATE / 'tenants.json', '{}')
    # Prevent the old foundation setup from overwriting tenant-aware routes.
    write(STATE / 'tenants-enrolled', 'Tenant manager owns relay configuration.\n')
    write('/usr/local/sbin/relay-health', f'''#!/usr/bin/env bash
set -euo pipefail
systemctl is-active --quiet haproxy
systemctl is-active --quiet snap.certbot.renew.timer
openssl x509 -in /etc/letsencrypt/live/relay/cert.pem -checkend 86400 -noout
status=$(curl --silent --show-error --max-time 10 --retry 5 --retry-connrefused --retry-delay 1 --noproxy '*' --connect-to '{ip}:19999:127.0.0.1:19999' --output /dev/null --write-out '%{{http_code}}' 'https://{ip}:19999/')
[[ "$status" == 200 ]]
printf 'Relay TLS and renewal healthy.\\n'
''', 0o755)
    run('systemctl', 'daemon-reload')
    render(settings, json.loads((STATE / 'tenants.json').read_text()))
    run('/usr/local/sbin/relay-health')


def enroll(settings, tenants, name, port, public_key):
    if name in tenants:
        raise ValueError('Tenant ID already used; use a fresh ID (revoked slots stay reserved)')
    if not settings['first'] <= port <= settings['last']:
        raise ValueError('Port outside provisioned range')
    if any(t['port'] == port for t in tenants.values()):
        raise ValueError('Port is reserved, including revoked tenants')
    parts = public_key.strip().split()
    if len(parts) < 2 or parts[0] != 'ssh-ed25519' or not re.fullmatch(r'[A-Za-z0-9+/]+=*', parts[1]):
        raise ValueError('Supply an Ed25519 public key without authorized_keys options')
    directory = CONFIG / 'tenants' / name
    directory.mkdir(mode=0o755, exist_ok=True)
    write(directory / 'authorized_keys', f'{parts[0]} {parts[1]}\n', 0o644)
    run('ssh-keygen', '-l', '-f', str(directory / 'authorized_keys'))
    username = f'relay_{name}'
    # PAM would move authenticated sshd children into user.slice, outside this
    # service's resource/revocation boundary. Keep PAM off and give the account
    # an unknown random password hash so OpenSSH does not reject it as locked.
    # Password and keyboard-interactive authentication remain disabled.
    password_hash = subprocess.run(['openssl', 'passwd', '-6', '-stdin'],
                                   input=secrets.token_hex(32), text=True,
                                   capture_output=True, check=True).stdout.strip()
    run('useradd', '--system', '--no-create-home', '--shell', '/usr/sbin/nologin',
        '--password', password_hash, username)
    write(directory / 'sshd_config', f'''Port {port + 20000}
ListenAddress 0.0.0.0
HostKey /etc/ssh/ssh_host_ed25519_key
PidFile /run/relay-tunnel-{name}.pid
AllowUsers {username}
AuthorizedKeysFile {directory}/authorized_keys
AuthenticationMethods publickey
PubkeyAuthentication yes
PasswordAuthentication no
KbdInteractiveAuthentication no
UsePAM no
PermitRootLogin no
AllowTcpForwarding remote
PermitListen 127.0.0.1:{port + 10000}
PermitOpen none
GatewayPorts no
AllowStreamLocalForwarding no
AllowAgentForwarding no
X11Forwarding no
PermitTunnel no
PermitTTY no
PermitUserRC no
MaxSessions 0
MaxStartups 3:50:6
LoginGraceTime 20
ClientAliveInterval 15
ClientAliveCountMax 3
LogLevel VERBOSE
''')
    run('sshd', '-t', '-f', str(directory / 'sshd_config'))
    # Reserve before activation so partial failures never make the slot reusable.
    tenants[name] = dict(port=port, active=False)
    write(STATE / 'tenants.json', json.dumps(tenants, indent=2))
    run('systemctl', 'enable', '--now', f'relay-tunnel@{name}.service')
    tenants[name]['active'] = True
    try:
        render(settings, tenants)
    except Exception:
        run('systemctl', 'disable', '--now', f'relay-tunnel@{name}.service')
        raise
    write(STATE / 'tenants.json', json.dumps(tenants, indent=2))
    return dict(tenant=name, ip=settings['ip'], port=port, ssh_port=port + 20000,
                tunnel_port=port + 10000, ssh_user=username,
                host_key=Path('/etc/ssh/ssh_host_ed25519_key.pub').read_text().strip())


def revoke(settings, tenants, name):
    tenant = tenants[name]
    # Invalidate key first, then kill the entire per-tenant cgroup, including
    # privileged monitors and in-flight authentication. Other tenants are untouched.
    write(CONFIG / 'tenants' / name / 'authorized_keys', '')
    run('systemctl', 'disable', '--now', f'relay-tunnel@{name}.service')
    tenant['active'] = False
    write(STATE / 'tenants.json', json.dumps(tenants, indent=2))
    render(settings, tenants)
    print(json.dumps(dict(tenant=name, revoked=True, port_reserved=tenant['port'])))


def main():
    if os.geteuid() != 0:
        raise ValueError('Must run as root')
    STATE.mkdir(mode=0o755, exist_ok=True)
    with open('/run/mac-egress-relay-setup.lock', 'w') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        action = sys.argv[1]
        if action == 'init' and len(sys.argv) == 5:
            initialize(sys.argv[2], int(sys.argv[3]), int(sys.argv[4]))
            return
        settings = json.loads((STATE / 'settings.json').read_text())
        tenants = json.loads((STATE / 'tenants.json').read_text())
        if action == 'list':
            print(json.dumps(tenants, indent=2))
            return
        name = sys.argv[2]
        if not re.fullmatch(r'[a-z][a-z0-9]{0,19}', name):
            raise ValueError('Tenant ID must be 1–20 lowercase letters/digits, starting with a letter')
        if action == 'enroll' and len(sys.argv) == 4:
            print(json.dumps(enroll(settings, tenants, name, int(sys.argv[3]), sys.stdin.read()), indent=2))
        elif action == 'revoke' and len(sys.argv) == 3:
            revoke(settings, tenants, name)
        else:
            raise ValueError('Usage: relay-tenant init IP FIRST LAST | list | enroll ID PORT < key.pub | revoke ID')


if __name__ == '__main__':
    try:
        main()
    except (ValueError, KeyError, IndexError, OSError, subprocess.CalledProcessError) as error:
        sys.exit(str(error))
