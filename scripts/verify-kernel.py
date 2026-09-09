#!/usr/bin/env python3
"""Exercise an active sharing session using the Kernel CLI; delete owned resources."""

import argparse
import ipaddress
import json
import os
from pathlib import Path
import re
import signal
import subprocess
import sys
import uuid


class VerificationError(Exception):
    pass


def command(args, *, as_json=False):
    # Do not echo argv/stderr: the proxy CLI accepts credentials as arguments.
    try:
        result = subprocess.run(args, capture_output=True, text=True, timeout=120)
    except subprocess.TimeoutExpired:
        raise VerificationError(f"{args[0]} timed out; inspect the recovery record") from None
    if result.returncode:
        raise VerificationError(f"{args[0]} {' '.join(args[1:3])} failed (exit {result.returncode})")
    return json.loads(result.stdout) if as_json else result.stdout.strip()


def kernel(*args):
    return command(["kernel", *args, "-o", "json"], as_json=True)


def playwright(session_id, code):
    result = kernel("browsers", "playwright", "execute", session_id, code, "--timeout", "70")
    if not result.get("success"):
        raise VerificationError("Browser execution failed")
    return result["result"]


def disconnected(item):
    if "status" in item:
        return item["status"] == 502 and item.get("error") == "upstream_connect_failed"
    return bool(re.search(
        r"net::ERR_(PROXY_CONNECTION_FAILED|TUNNEL_CONNECTION_FAILED|CONNECTION_CLOSED|CONNECTION_RESET|EMPTY_RESPONSE)\b",
        item.get("error", "")))


def cleanup(state, save):
    # Removing a proxy while a browser still uses it can enable direct egress.
    for field, resource in (("browser_id", "browsers"), ("proxy_id", "proxies")):
        resource_id = state.get(field)
        if not resource_id or state.get(field + "_deleted"):
            continue
        args = ["kernel", resource, "delete", resource_id]
        if resource == "proxies":
            args.append("--yes")
        for attempt in range(3):
            try:
                command(args)
                break
            except VerificationError:
                if attempt == 2:
                    # Stop here if browser deletion fails. Never delete its proxy.
                    raise
        state[field + "_deleted"] = True
        save()
        print(f"Deleted {resource}: {resource_id}", flush=True)


def verify(manifest, credentials, output, revoke_stack=None):
    output.mkdir(mode=0o700)  # Refuse to overwrite a previous run's recovery data.
    state = {"name": "mac-egress-check-" + uuid.uuid4().hex[:12]}

    def save():
        (output / "result.json").write_text(json.dumps(state, indent=2) + "\n")

    save()
    try:
        direct = command(["curl", "-4", "--noproxy", "*", "--fail", "--silent",
                          "--show-error", "--max-time", "20", "https://checkip.amazonaws.com/"])
        state["mac_ip"] = str(ipaddress.IPv4Address(direct))
        proxy = kernel("proxies", "create", "--type", "custom", "--protocol", "https",
                       "--host", manifest["ip"], "--port", str(manifest["port"]),
                       "--username", credentials["username"], "--password", credentials["password"],
                       "--name", state["name"])
        state["proxy_id"] = proxy["id"]
        save()
        check = kernel("proxies", "check", state["proxy_id"])
        state["proxy_status"] = check.get("status")
        if check.get("status") != "available":
            raise VerificationError("Kernel proxy health check did not report available")
        browser = kernel("browsers", "create", "--proxy-id", state["proxy_id"],
                         "--name", state["name"], "--timeout", "300")
        state["browser_id"] = browser["session_id"]
        save()
        result = playwright(state["browser_id"], """
          const ips = [];
          for (const host of ["checkip.amazonaws.com", "api.ipify.org"]) {
            const response = await page.goto("https://" + host + "/?egress=" + Date.now(),
              {waitUntil: "domcontentloaded", timeout: 25000});
            if (!response.ok()) throw new Error("IP service returned an error");
            ips.push((await page.locator("body").innerText()).trim());
          }
          return {ips};
        """)
        state["browser_ips"] = result["ips"]
        if len(result["ips"]) != 2 or any(ip != direct for ip in result["ips"]):
            raise VerificationError("Browser egress does not match the Mac's public IPv4")
        print(f"PASS: both browser IP checks match Mac egress {direct}", flush=True)
        save()
        if revoke_stack:
            tenant_script = str(Path(__file__).resolve().with_name("tenant.sh"))
            command([tenant_script, "revoke", revoke_stack, manifest["tenant"]])
            state["tenant_revoked"] = True
            save()
            # A new context has no pooled site connections, cache, or service workers.
            result = playwright(state["browser_id"], """
              const fresh = await page.context().browser().newContext({serviceWorkers: "block"});
              try {
                const p = await fresh.newPage();
                const failures = [];
                for (const host of ["checkip.amazonaws.com", "api.ipify.org"]) {
                  try {
                    const response = await p.goto("https://" + host + "/?disconnected=" + Date.now(),
                      {waitUntil: "domcontentloaded", timeout: 20000});
                    const body = await p.locator("body").innerText();
                    failures.push({host, status: response.status(),
                      error: body.includes("upstream_connect_failed") ? "upstream_connect_failed" : "unexpected_response"});
                  } catch (error) {
                    const message = String(error);
                    failures.push({host, error: message.split("\\n")[0]});
                  }
                }
                return {failures};
              } finally { await fresh.close(); }
            """)
            state["disconnect"] = result["failures"]
            save()
            if len(result["failures"]) != 2 or not all(disconnected(item) for item in result["failures"]):
                raise VerificationError("Fresh browser requests did not fail with expected proxy/network errors")
            print("PASS: both fresh browser requests fail after tenant revocation", flush=True)
        state["passed"] = True
    finally:
        save()
        cleanup(state, save)
    return state


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("manifest", type=Path)
    parser.add_argument("session", type=Path, help="Active start-tenant.sh session directory")
    parser.add_argument("output", type=Path, help="New private directory for non-secret recovery/results")
    parser.add_argument("--revoke", metavar="STACK", help="Permanently revoke this tenant and test failure; needs AWS access")
    args = parser.parse_args()
    if not os.environ.get("KERNEL_API_KEY"):
        parser.error("Set KERNEL_API_KEY in the environment")
    os.umask(0o077)
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(143))
    try:
        verify(json.loads(args.manifest.read_text()),
               json.loads((args.session / "credentials.json").read_text()), args.output, args.revoke)
    except (VerificationError, OSError, ValueError, KeyError) as error:
        # Unexpected exceptions should not print request data/credentials either.
        print(f"Verification failed ({type(error).__name__}). Inspect {args.output}/result.json; "
              "clean up any recorded browser before its proxy. If creation was interrupted, "
              "look up resources by the recorded unique name.", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
