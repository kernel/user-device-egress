"""Offline ownership/cleanup tests; no cloud resources or credentials required."""

import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import Mock, patch


spec = importlib.util.spec_from_file_location(
    "verify_kernel", Path(__file__).resolve().parents[1] / "scripts" / "verify-kernel.py")
verify_kernel = importlib.util.module_from_spec(spec)
spec.loader.exec_module(verify_kernel)


class CleanupTests(unittest.TestCase):
    def test_disconnect_requires_an_explicit_proxy_or_network_error(self):
        self.assertTrue(verify_kernel.disconnected({"status": 502, "error": "upstream_connect_failed"}))
        self.assertTrue(verify_kernel.disconnected({"error": "page.goto: net::ERR_TUNNEL_CONNECTION_FAILED at https://example.com"}))
        self.assertFalse(verify_kernel.disconnected({"status": 200, "error": "upstream_connect_failed"}))
        self.assertFalse(verify_kernel.disconnected({"status": 502, "error": "unexpected_response"}))
        self.assertFalse(verify_kernel.disconnected({"error": "Timeout 20000ms exceeded"}))

    def test_browser_is_deleted_before_proxy(self):
        state = {"browser_id": "owned-browser", "proxy_id": "owned-proxy"}
        with patch.object(verify_kernel, "command") as command:
            verify_kernel.cleanup(state, Mock())
        self.assertEqual([call.args[0] for call in command.call_args_list], [
            ["kernel", "browsers", "delete", "owned-browser"],
            ["kernel", "proxies", "delete", "owned-proxy", "--yes"],
        ])
        self.assertTrue(state["browser_id_deleted"])
        self.assertTrue(state["proxy_id_deleted"])

    def test_browser_delete_failure_preserves_proxy(self):
        state = {"browser_id": "owned-browser", "proxy_id": "owned-proxy"}
        with patch.object(verify_kernel, "command", side_effect=verify_kernel.VerificationError("offline")) as command:
            with self.assertRaises(verify_kernel.VerificationError):
                verify_kernel.cleanup(state, Mock())
        self.assertEqual(command.call_count, 3)
        self.assertTrue(all(call.args[0][1] == "browsers" for call in command.call_args_list))
        self.assertNotIn("proxy_id_deleted", state)

    def test_already_deleted_resources_are_skipped(self):
        state = {"browser_id": "owned-browser", "browser_id_deleted": True,
                 "proxy_id": "owned-proxy", "proxy_id_deleted": True}
        with patch.object(verify_kernel, "command") as command:
            verify_kernel.cleanup(state, Mock())
        command.assert_not_called()

    def test_wrong_egress_still_cleans_up_and_never_saves_secrets(self):
        manifest = {"ip": "192.0.2.20", "port": 20000, "tenant": "test"}
        credentials = {"username": "session", "password": "secret-that-must-not-be-saved"}
        responses = [{"id": "owned-proxy"}, {"status": "available"}, {"session_id": "owned-browser"}]
        with tempfile.TemporaryDirectory() as temporary:
            output = Path(temporary) / "run"
            with patch.object(verify_kernel, "command", return_value="203.0.113.10") as command, \
                    patch.object(verify_kernel, "kernel", side_effect=responses), \
                    patch.object(verify_kernel, "playwright", return_value={"ips": ["192.0.2.1", "192.0.2.1"]}):
                with self.assertRaises(verify_kernel.VerificationError):
                    verify_kernel.verify(manifest, credentials, output)
            saved = (output / "result.json").read_text()
            self.assertNotIn(credentials["password"], saved)
            state = json.loads(saved)
            self.assertTrue(state["browser_id_deleted"])
            self.assertTrue(state["proxy_id_deleted"])
            self.assertEqual(command.call_count, 3)

    def test_existing_output_is_not_overwritten(self):
        with tempfile.TemporaryDirectory() as temporary:
            with patch.object(verify_kernel, "command") as command:
                with self.assertRaises(FileExistsError):
                    verify_kernel.verify({}, {}, Path(temporary))
            command.assert_not_called()


if __name__ == "__main__":
    unittest.main()
