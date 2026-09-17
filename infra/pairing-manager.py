#!/usr/bin/python3 -I
"""Privileged, narrowly scoped invitation issuer/redeemer. No network listener."""
import base64
import fcntl
import hashlib
import importlib.machinery
import importlib.util
import json
import os
from pathlib import Path
import re
import secrets
import struct
import sys
import time


def canonical_key(value):
    if not isinstance(value, str) or len(value) > 256:
        raise ValueError('Invalid device key')
    parts = value.strip().split()
    if len(parts) != 2 or parts[0] != 'ssh-ed25519':
        raise ValueError('Invalid device key')
    try:
        wire = base64.b64decode(parts[1], validate=True)
    except ValueError:
        raise ValueError('Invalid device key') from None
    prefix = struct.pack('>I', 11) + b'ssh-ed25519' + struct.pack('>I', 32)
    if len(wire) != len(prefix) + 32 or not wire.startswith(prefix):
        raise ValueError('Invalid device key')
    return 'ssh-ed25519 ' + base64.b64encode(wire).decode()


class Pairing:
    # All methods run under the tenant manager's shared process lock.
    def __init__(self, manager, clock=time.time):
        self.manager, self.clock = manager, clock
        self.directory = manager.STATE / 'invitations'
        self.directory.mkdir(mode=0o700, exist_ok=True)

    def issue(self, name):
        if not re.fullmatch(r'[a-z][a-z0-9]{0,19}', name):
            raise ValueError('Use a new device name: 1–20 lowercase letters/digits')
        settings = json.loads((self.manager.STATE / 'settings.json').read_text())
        tenants = json.loads((self.manager.STATE / 'tenants.json').read_text())
        pending = [json.loads(p.read_text()) for p in self.directory.glob('*.json')]
        pending = [r for r in pending if r['expires'] > self.clock()]
        if name in tenants or any(r['name'] == name for r in pending):
            raise ValueError('Device name is already enrolled or has an unexpired invitation')
        used = {t['port'] for t in tenants.values()} | {r['port'] for r in pending}
        port = next((p for p in range(settings['first'], settings['last'] + 1) if p not in used), None)
        if port is None:
            raise ValueError('No free device slots; extend the relay range first')
        token = secrets.token_urlsafe(32)
        digest = hashlib.sha256(token.encode()).hexdigest()
        expires = int(self.clock()) + 600
        record = dict(name=name, port=port, expires=expires, phase='issued')
        self.manager.write(self.directory / (digest + '.json'), json.dumps(record))
        return dict(url=f"https://{settings['ip']}/pair#{token}", expires=expires, device=name)

    def redeem(self, payload):
        token = payload.get('token')
        if not isinstance(token, str) or not re.fullmatch(r'[A-Za-z0-9_-]{43}', token):
            return 403, dict(error='Invalid or expired pairing code')
        path = self.directory / (hashlib.sha256(token.encode()).hexdigest() + '.json')
        if not path.exists():
            return 403, dict(error='Invalid or expired pairing code')
        record = json.loads(path.read_text())
        if record['expires'] <= self.clock():
            return 410, dict(error='Pairing code expired; request a new one')
        key = canonical_key(payload.get('public_key'))
        if record.get('key') not in (None, key):
            return 409, dict(error='This code has already paired another device')
        tenants = json.loads((self.manager.STATE / 'tenants.json').read_text())
        if record['phase'] == 'complete':
            tenant = tenants.get(record['name'], {})
            if not tenant.get('active'):
                return 410, dict(error='This device enrollment was revoked')
            return 200, record['manifest']
        if record['phase'] != 'issued':
            return 409, dict(error='Pairing was interrupted; ask the relay administrator to reconcile it')
        settings = json.loads((self.manager.STATE / 'settings.json').read_text())
        # Bind and consume before any side effects. A failed/ambiguous enrollment
        # cannot retry user creation or enroll a second key into a reserved slot.
        record.update(key=key, phase='enrolling')
        self.manager.write(path, json.dumps(record))
        manifest = self.manager.enroll(settings, tenants, record['name'], record['port'], key)
        record.update(phase='complete', manifest=manifest)
        self.manager.write(path, json.dumps(record))
        return 200, manifest


def main():
    if os.geteuid() != 0:
        raise ValueError('Must run as root')
    loader = importlib.machinery.SourceFileLoader('relay_tenant', '/usr/local/sbin/relay-tenant')
    spec = importlib.util.spec_from_loader(loader.name, loader)
    manager = importlib.util.module_from_spec(spec)
    loader.exec_module(manager)
    with open('/run/mac-egress-relay-setup.lock', 'w') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        pairing = Pairing(manager)
        if len(sys.argv) == 3 and sys.argv[1] == 'issue':
            print(json.dumps(pairing.issue(sys.argv[2])))
        elif sys.argv[1:] == ['redeem']:
            raw = sys.stdin.buffer.read(4097)
            if len(raw) > 4096:
                raise ValueError('Request too large')
            payload = json.loads(raw)
            if not isinstance(payload, dict):
                raise ValueError('Invalid request')
            status, body = pairing.redeem(payload)
            print(json.dumps(dict(status=status, body=body)))
        else:
            raise ValueError('Usage: relay-pair issue DEVICE | redeem')


if __name__ == '__main__':
    try:
        main()
    except Exception:
        # Never echo request bodies, bearer tokens, or subprocess details.
        sys.exit('Pairing operation failed; inspect relay state before retrying')
