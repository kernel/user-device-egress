#!/usr/bin/env python3
"""Redeem a disposable invitation over verified HTTPS, then test safe retries.

Creates one relay tenant, no Kernel resources. Revoke that test tenant afterward.
"""
import argparse
import base64
import json
import secrets
import struct
from pathlib import Path
import urllib.error
import urllib.parse
import urllib.request


class NoRedirects(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *args, **kwargs):
        return None


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('invitation', type=Path)
    parser.add_argument('public_key', type=Path)
    parser.add_argument('manifest', type=Path)
    args = parser.parse_args()
    invitation = json.loads(args.invitation.read_text())
    url = urllib.parse.urlsplit(invitation['url'])
    assert url.scheme == 'https' and url.path == '/pair'
    endpoint = urllib.parse.urlunsplit((url.scheme, url.netloc, '/v1/pair', '', ''))
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), NoRedirects())
    key = args.public_key.read_text().strip().split()
    key = ' '.join(key[:2])

    def redeem(public_key, token=url.fragment):
        body = json.dumps(dict(token=token, public_key=public_key)).encode()
        request = urllib.request.Request(endpoint, data=body, headers={'Content-Type': 'application/json'})
        try:
            with opener.open(request, timeout=60) as response:
                return response.status, response.read(16384)
        except urllib.error.HTTPError as error:
            return error.code, error.read(16384)

    assert redeem(key, 'x' * 43)[0] == 403, 'Invalid invitation accepted'
    status, body = redeem(key)
    assert status == 200, f'Enrollment returned {status}'
    with args.manifest.open('x') as output:
        output.write(body.decode())
    args.manifest.chmod(0o600)
    assert redeem(key) == (status, body), 'Same-device retry changed enrollment'
    wire = struct.pack('>I', 11) + b'ssh-ed25519' + struct.pack('>I', 32) + secrets.token_bytes(32)
    other_key = 'ssh-ed25519 ' + base64.b64encode(wire).decode()
    assert redeem(other_key)[0] == 409, 'Invitation allowed a second device'
    print('PASS: trusted HTTPS, enrollment, same-key retry, and second-device rejection.')


if __name__ == '__main__':
    main()
