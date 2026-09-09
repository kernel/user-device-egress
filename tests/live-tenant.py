#!/usr/bin/env python3
"""Live checks for operator-created test tenants. --revoke explicitly retires one."""
import argparse
import base64
import json
from pathlib import Path
import socket
import ssl
import subprocess
import time


def command(*args):
    return subprocess.run(args, capture_output=True, text=True, timeout=30)


def proxy_status(session, url, endpoint=None):
    args = ['curl', '--config', str(session / 'curl.conf'), '--silent', '--max-time', '15',
            '--output', '/dev/null', '--write-out', '%{http_connect}']
    if endpoint:
        args += ['--proxy', endpoint]
    return command(*args, url).stdout.strip()


def exit_ip(session=None):
    args = ['curl', '--fail', '--silent', '--show-error', '--max-time', '15']
    if session:
        args += ['--config', str(session / 'curl.conf')]
    else:
        args += ['-4', '--noproxy', '*']
    result = command(*args, 'https://checkip.amazonaws.com/')
    assert result.returncode == 0, result.stderr
    return result.stdout.strip()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('manifest', type=Path)
    parser.add_argument('key', type=Path)
    parser.add_argument('session', type=Path)
    parser.add_argument('--other-manifest', type=Path, required=True)
    parser.add_argument('--other-session', type=Path, required=True)
    parser.add_argument('--revoke', metavar='STACK', help='Revoke the first test tenant and verify live disconnect')
    args = parser.parse_args()
    tenant = json.loads(args.manifest.read_text())
    other = json.loads(args.other_manifest.read_text())
    endpoint = f"https://{tenant['ip']}:{tenant['port']}"
    expected = exit_ip()
    assert exit_ip(args.session) == expected
    assert exit_ip(args.other_session) == expected
    print(f'Direct Mac and both tenant routes match: {expected}', flush=True)

    result = command('curl', '--silent', '--max-time', '10', '--noproxy', '', '--proxy', endpoint,
                     '--output', '/dev/null', '--write-out', '%{http_connect}', 'https://checkip.amazonaws.com/')
    assert result.stdout == '407', ('missing authentication', result.stdout, result.stderr)
    assert proxy_status(args.session, 'https://127.0.0.1/') == '403'
    assert proxy_status(args.session, 'https://checkip.amazonaws.com:22/') == '403'
    assert proxy_status(args.session, 'https://checkip.amazonaws.com/', f"https://{other['ip']}:{other['port']}") == '407'
    print('Missing credentials, cross-tenant credentials, private destination, and disallowed port rejected.', flush=True)

    ssh = ['ssh', '-F', '/dev/null', '-i', str(args.key),
           '-o', f"UserKnownHostsFile={args.session / 'known_hosts'}", '-o', 'GlobalKnownHostsFile=/dev/null',
           '-o', 'StrictHostKeyChecking=yes', '-o', 'BatchMode=yes', '-o', 'IdentitiesOnly=yes',
           '-o', 'ConnectTimeout=5', '-o', 'ExitOnForwardFailure=yes']
    target = f"{tenant['ssh_user']}@{tenant['ip']}"
    checks = [
        (['-p', str(tenant['ssh_port']), target, 'true'], 'open failed'),
        (['-p', str(tenant['ssh_port']), '-W', '127.0.0.1:22', target], 'administratively prohibited'),
        (['-p', str(tenant['ssh_port']), '-N', '-R', '127.0.0.1:39999:127.0.0.1:18080', target], 'remote port forwarding failed'),
        (['-p', str(other['ssh_port']), '-o', f"HostKeyAlias=[{tenant['ip']}]:{tenant['ssh_port']}",
          f"{other['ssh_user']}@{other['ip']}", 'true'], 'permission denied'),
    ]
    for arguments, expected_error in checks:
        result = command(*ssh, *arguments)
        assert result.returncode != 0 and expected_error in result.stderr.lower(), (arguments, result.stderr)
    print('Shell, local forwarding, unassigned remote port, and cross-tenant SSH identity rejected.', flush=True)

    if not args.revoke:
        return
    credentials = json.loads((args.session / 'credentials.json').read_text())
    basic = base64.b64encode(f"{credentials['username']}:{credentials['password']}".encode()).decode()
    context = ssl.create_default_context()
    with context.wrap_socket(socket.create_connection((tenant['ip'], tenant['port']), timeout=10), server_hostname=tenant['ip']) as stream:
        stream.sendall(('CONNECT checkip.amazonaws.com:443 HTTP/1.1\r\nHost: checkip.amazonaws.com:443\r\n'
                        f'Proxy-Authorization: Basic {basic}\r\n\r\n').encode())
        response = b''
        while b'\r\n\r\n' not in response:
            chunk = stream.recv(1)
            assert chunk, 'CONNECT closed before response headers'
            response += chunk
            assert len(response) < 8192
        assert response.startswith(b'HTTP/1.1 200'), response
        print('Live CONNECT established; revoking its tenant now.', flush=True)
        started = time.monotonic()
        script = Path(__file__).resolve().parent.parent / 'scripts' / 'tenant.sh'
        result = command(str(script), 'revoke', args.revoke, tenant['tenant'])
        assert result.returncode == 0, result.stderr
        stream.settimeout(5)
        assert stream.recv(1) == b'', 'Existing tunnel survived revocation'
        print(f'Existing CONNECT closed after revocation ({time.monotonic() - started:.1f}s including AWS/SSH control calls).', flush=True)
    # Allow the graceful HAProxy reload to switch new listeners; all old workers
    # are already unable to reach the stopped tenant's loopback tunnel.
    time.sleep(1)
    assert proxy_status(args.session, 'https://checkip.amazonaws.com/') == '503'
    result = command(*ssh, '-p', str(tenant['ssh_port']), '-N', target)
    assert result.returncode != 0
    assert exit_ip(args.other_session) == expected
    print('Revoked endpoint rejects new traffic; revoked SSH cannot reconnect; other tenant still works.', flush=True)


if __name__ == '__main__':
    main()
