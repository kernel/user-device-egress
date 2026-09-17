import base64
import importlib.util
import json
from pathlib import Path
import struct
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import Mock

spec = importlib.util.spec_from_file_location('pairing', Path(__file__).parents[1] / 'infra/pairing-manager.py')
pairing = importlib.util.module_from_spec(spec)
spec.loader.exec_module(pairing)


def key(byte=1):
    return 'ssh-ed25519 ' + base64.b64encode(struct.pack('>I', 11) + b'ssh-ed25519' + struct.pack('>I', 32) + bytes([byte]) * 32).decode()


class PairingTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        (self.root / 'settings.json').write_text(json.dumps(dict(ip='1.1.1.1', first=20000, last=20002)))
        (self.root / 'tenants.json').write_text(json.dumps(dict(mac=dict(port=20000, active=True))))
        self.now = 1000
        def enroll(settings, tenants, name, port, public_key):
            tenants[name] = dict(port=port, active=True)
            (self.root / 'tenants.json').write_text(json.dumps(tenants))
            return dict(tenant=name, ip=settings['ip'], port=port)
        self.manager = SimpleNamespace(STATE=self.root, write=lambda p, s: p.write_text(s), enroll=Mock(side_effect=enroll))
        self.service = pairing.Pairing(self.manager, clock=lambda: self.now)

    def invite(self, name='phone'):
        return self.service.issue(name)['url'].split('#')[1]

    def redeem(self, token, public_key=None):
        return self.service.redeem(dict(token=token, public_key=public_key or key()))

    def test_issue_reserves_only_unused_slots_and_hashes_secret(self):
        token = self.invite()
        record = next(self.service.directory.glob('*.json')).read_text()
        self.assertNotIn(token, record)
        self.assertEqual(json.loads(record)['port'], 20001)
        self.assertEqual(json.loads(record)['expires'], 1600)
        self.invite('second')
        with self.assertRaises(ValueError): self.invite('third')
        self.manager.enroll.assert_not_called()

    def test_same_key_retry_is_idempotent_other_device_rejected(self):
        token = self.invite()
        first = self.redeem(token)
        self.assertEqual(first[0], 200)
        self.assertEqual(self.redeem(token), first)
        self.assertEqual(self.redeem(token, key(2))[0], 409)
        self.manager.enroll.assert_called_once()

    def test_expiry_invalid_tokens_and_revocation(self):
        token = self.invite()
        for invalid in ['', '../etc/shadow', 'x' * 43, None]:
            self.assertEqual(self.redeem(invalid)[0], 403)
        self.now = 1600
        self.assertEqual(self.redeem(token)[0], 410)
        self.manager.enroll.assert_not_called()
        self.now = 1000
        self.redeem(token)
        (self.root / 'tenants.json').write_text(json.dumps(dict(phone=dict(port=20001, active=False))))
        self.assertEqual(self.redeem(token)[0], 410)

    def test_failed_enrollment_never_runs_twice(self):
        token = self.invite()
        self.manager.enroll.side_effect = RuntimeError('partial failure')
        with self.assertRaises(RuntimeError): self.redeem(token)
        self.assertEqual(self.redeem(token)[0], 409)
        self.assertEqual(self.redeem(token, key(2))[0], 409)
        self.manager.enroll.assert_called_once()

    def test_malformed_keys_cannot_consume_invitation(self):
        token = self.invite()
        for invalid in ['restrict ' + key(), key() + '\n' + key(2), 'ssh-ed25519 AAAA', 42, 'ssh-rsa AAAA']:
            with self.assertRaises(ValueError): self.redeem(token, invalid)
        self.manager.enroll.assert_not_called()
        self.assertEqual(self.redeem(token)[0], 200)

    def test_expired_unclaimed_invite_releases_reservation(self):
        self.invite()
        with self.assertRaises(ValueError): self.invite()
        self.now = 1601
        self.invite()
        with self.assertRaises(ValueError): self.invite('../bad')


if __name__ == '__main__': unittest.main()
