#!/usr/bin/env python3
"""Exercise bundled app helpers with an enrolled test device; never create Kernel resources."""
import argparse
import json
from pathlib import Path
import queue
import signal
import subprocess
import tempfile
import threading
import time


def run_case(helper, proxy, device, mode):
    # Match Application Support: OpenSSH's -o parser must handle spaces in this path.
    with tempfile.TemporaryDirectory(prefix="mac egress app test ") as root:
        process = subprocess.Popen([str(helper), "-proxy", str(proxy), "-sessions", root],
                                   stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                                   text=True)
        events = queue.Queue()

        def read_events():
            for line in process.stdout:
                events.put(json.loads(line))
            events.put({"event": "exited"})

        threading.Thread(target=read_events, daemon=True).start()
        directory = None
        try:
            process.stdin.write(json.dumps(device) + "\n")
            process.stdin.flush()
            deadline = time.monotonic() + 60
            while time.monotonic() < deadline:
                event = events.get(timeout=60)
                if event["event"] in ("exited", "error"):
                    raise AssertionError("Helper failed before verifying egress: " + event.get("message", "exited"))
                if event["event"] == "sharing":
                    directory = Path(event["directory"])
                    assert directory.is_relative_to(Path(root))
                    assert directory.stat().st_mode & 0o777 == 0o700
                    assert (directory / "credentials.json").stat().st_mode & 0o777 == 0o600
                    print(f"PASS {mode}: verified Mac egress {event['ip']}", flush=True)
                    break
            assert directory is not None, "never reached sharing state"
            if mode == "stdin-eof":
                process.stdin.close()  # Same OS-level pipe closure as an app crash/force-quit.
            elif mode == "stop":
                process.send_signal(signal.SIGTERM)
            else:
                children = subprocess.check_output(["pgrep", "-P", str(process.pid)], text=True).split()
                assert len(children) == 2, "expected one proxy and one SSH child"
                subprocess.run(["kill", "-KILL", children[0]], check=True)
            process.wait(timeout=5)
            assert not directory.exists(), "session credentials were not removed"
            remaining = subprocess.run(["pgrep", "-g", str(process.pid)], capture_output=True)
            assert remaining.returncode == 1, "helper left processes in its group"
            print(f"PASS {mode}: both children stopped and private session files removed", flush=True)
        finally:
            if process.poll() is None:
                process.terminate()
                process.wait(timeout=5)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("executables", type=Path, help="Built MacEgress.app/Contents/MacOS directory")
    parser.add_argument("manifest", type=Path)
    parser.add_argument("key", type=Path)
    args = parser.parse_args()
    device = {"manifest": json.loads(args.manifest.read_text()), "private_key": args.key.read_text()}
    for mode in ("stop", "stdin-eof", "child-crash"):
        run_case(args.executables / "mac-session", args.executables / "mac-proxy", device, mode)


if __name__ == "__main__":
    main()
