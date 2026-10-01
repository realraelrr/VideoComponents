#!/usr/bin/env python3
"""Capture real Simulator pixels for application-host XCTest without XCUIAutomation.

Start before the consumer test action, using a fresh absolute mailbox directory:
  python3 Scripts/capture-player-screen.py --directory /tmp/capture-run --udid UUID
Pass TEST_RUNNER_VIDEO_COMPONENTS_CAPTURE_DIRECTORY=/tmp/capture-run to xcodebuild.
The test host reads VIDEO_COMPONENTS_CAPTURE_DIRECTORY (the TEST_RUNNER_ prefix is
stripped by Xcode). No Simulator is booted, no app is launched, and no image is made
or substituted by this driver: every PNG comes from simctl io <exact UUID> screenshot.

Protocol v1: driver.json advertises a runToken and state=ready. Tests atomically
publish <token>.request.json with test/stage, Simulator UDID, media ROI in screen
points, screen bounds, native facts, and an expiration. The driver retains each
request, command log, and PNG, then atomically publishes <token>.response.json.
Responses echo both tokens and UDID. Failure responses retain the original error.
The test verifies identity/freshness and samples the PNG itself; the driver never
judges pixels. Missing configuration/capture is a test failure, not a skipped test.

To stop, create DIRECTORY/quit or send SIGTERM/SIGINT, then wait for this process.
Per-command, idle, and total watchdogs are finite. Cleanup kills/reaps only the
driver's own screenshot subprocess and releases its lock; evidence is preserved.
"""

import argparse
import hashlib
import json
import math
import os
from pathlib import Path
import signal
import struct
import subprocess
import sys
import threading
import time
import uuid


class CaptureFailure(RuntimeError):
    pass


def atomic_json(path, value):
    temporary = path.with_name(path.name + ".tmp-" + uuid.uuid4().hex)
    try:
        with temporary.open("x") as output:
            json.dump(value, output, indent=2, sort_keys=True, allow_nan=False)
            output.write("\n")
        os.replace(temporary, path)
    finally:
        temporary.unlink(missing_ok=True)


def positive_seconds(value):
    seconds = float(value)
    if not math.isfinite(seconds) or seconds <= 0:
        raise argparse.ArgumentTypeError("watchdogs must be finite positive seconds")
    return seconds


class Driver:
    def __init__(self, directory, udid, capture_timeout, idle_timeout, max_duration):
        self.directory = directory
        self.udid = str(uuid.UUID(udid)).upper()  # Rejects 'booted' and ambiguous device names.
        self.run_token = str(uuid.uuid4()).upper()
        self.capture_timeout = capture_timeout
        self.idle_timeout = idle_timeout
        self.max_duration = max_duration
        self.stop = threading.Event()
        self.stop_reason = "quit control file"
        self.deadline = time.monotonic() + max_duration
        self.last_request = time.monotonic()

    def state(self, value, failure=None):
        atomic_json(self.directory / "driver.json", {
            "protocolVersion": 1, "simulatorUDID": self.udid, "runToken": self.run_token,
            "state": value, "failure": failure, "processID": os.getpid(),
            "updatedAt": time.time(), "stopReason": self.stop_reason if value == "stopped" else None,
        })

    def stopping(self):
        return self.stop.is_set() or (self.directory / "quit").exists()

    def handle_signal(self, signum, _frame):
        self.stop_reason = signal.Signals(signum).name
        self.stop.set()

    def validate_request(self, path, request):
        token = path.name.removesuffix(".request.json")
        if str(uuid.UUID(token)).upper() != token:
            raise CaptureFailure("request filename must contain a canonical UUID token")
        expected = {"protocolVersion": 1, "token": token,
                    "runToken": self.run_token, "simulatorUDID": self.udid}
        if any(request.get(key) != value for key, value in expected.items()):
            raise CaptureFailure("request token, run token, protocol, or Simulator UDID mismatch")
        for key in ("test", "stage"):
            if not isinstance(request.get(key), str) or not request[key]:
                raise CaptureFailure("request is missing " + key)
        if not isinstance(request.get("nativeFacts"), dict):
            raise CaptureFailure("request is missing native readiness facts")
        for key in ("mediaROI", "screenBounds"):
            rect = request.get(key, {})
            if any(not isinstance(rect.get(field), (int, float))
                   or not math.isfinite(rect[field]) for field in ("x", "y", "width", "height")):
                raise CaptureFailure("invalid screen coordinate rectangle: " + key)
            if rect["width"] <= 0 or rect["height"] <= 0:
                raise CaptureFailure("empty screen coordinate rectangle: " + key)
        roi, bounds = request["mediaROI"], request["screenBounds"]
        if (roi["x"] < bounds["x"] or roi["y"] < bounds["y"]
                or roi["x"] + roi["width"] > bounds["x"] + bounds["width"]
                or roi["y"] + roi["height"] > bounds["y"] + bounds["height"]):
            raise CaptureFailure("requested media ROI is outside the screen")
        now = time.time()
        created, expires = request.get("createdAt"), request.get("expiresAt")
        if (not isinstance(created, (int, float)) or not isinstance(expires, (int, float))
                or not math.isfinite(created) or not math.isfinite(expires)
                or created > now or expires <= now or expires <= created or expires - created > 21):
            raise CaptureFailure("capture request is expired or has an invalid lifetime")
        return token

    @staticmethod
    def kill_and_reap(process):
        if process.poll() is None:
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
        return process.communicate(timeout=2)

    def screenshot(self, command, timeout):
        process = subprocess.Popen(command, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                                   stderr=subprocess.PIPE, text=True, start_new_session=True)
        deadline = time.monotonic() + timeout
        try:
            while True:
                reason = None
                if self.stopping():
                    reason = "simctl screenshot interrupted by " + self.stop_reason
                elif time.monotonic() >= deadline:
                    reason = f"simctl screenshot timed out after {timeout:.3f} seconds"
                if reason:
                    stdout, stderr = self.kill_and_reap(process)
                    raise CaptureFailure(f"{reason}; command={command!r}; stdout={stdout!r}; stderr={stderr!r}")
                try:
                    stdout, stderr = process.communicate(timeout=min(0.1, deadline - time.monotonic()))
                except subprocess.TimeoutExpired:
                    continue
                if process.returncode:
                    raise CaptureFailure(f"simctl screenshot exited {process.returncode}; command={command!r}; "
                                         f"stdout={stdout!r}; stderr={stderr!r}")
                return stdout, stderr
        finally:
            if process.poll() is None:
                self.kill_and_reap(process)

    def capture(self, path):
        token = path.name.removesuffix(".request.json")
        # Keep filenames safe even when publishing an error for a malformed request.
        if str(uuid.UUID(token)).upper() != token:
            raise CaptureFailure("invalid request filename: " + path.name)
        response = {"protocolVersion": 1, "token": token, "runToken": self.run_token,
                    "simulatorUDID": self.udid, "success": False}
        command = []
        started = time.time()
        try:
            request = json.loads(path.read_text())
            self.validate_request(path, request)
            output = self.directory / (token + ".png")
            temporary = self.directory / (token + ".capturing.png")
            if output.exists() or temporary.exists():
                raise CaptureFailure("refusing to reuse a PNG for request " + token)
            command = ["/usr/bin/xcrun", "simctl", "io", self.udid,
                       "screenshot", "--type=png", str(temporary)]
            timeout = min(self.capture_timeout, request["expiresAt"] - time.time(),
                          self.deadline - time.monotonic())
            if timeout <= 0:
                raise CaptureFailure("capture request/driver deadline expired before screenshot")
            started = time.time()
            stdout, stderr = self.screenshot(command, timeout)
            png = temporary.read_bytes()
            if len(png) < 33 or png[:8] != b"\x89PNG\r\n\x1a\n" or png[12:16] != b"IHDR":
                raise CaptureFailure("simctl did not produce a valid PNG header")
            width, height = struct.unpack(">II", png[16:24])
            if width == 0 or height == 0:
                raise CaptureFailure("simctl produced an empty PNG")
            if time.time() >= request["expiresAt"]:
                raise CaptureFailure("screenshot completed after the request expired")
            os.replace(temporary, output)
            response.update(success=True, png=output.name, byteCount=len(png),
                            sha256=hashlib.sha256(png).hexdigest(), width=width, height=height)
            log = f"command={command!r}\nstdout={stdout}\nstderr={stderr}\n"
        except (OSError, ValueError, TypeError, CaptureFailure, subprocess.SubprocessError) as error:
            # Do not replace this error with a later watchdog or shutdown message.
            response["failure"] = str(error)
            log = f"command={command!r}\nfailure={error}\n"
        response.update(captureStartedAt=started, captureFinishedAt=time.time())
        (self.directory / (token + ".capture.log")).write_text(log)
        atomic_json(self.directory / (token + ".response.json"), response)
        if not response["success"]:
            raise CaptureFailure(response["failure"])
        print(f"captured {token} {response['width']}x{response['height']}", flush=True)

    def watch(self):
        self.state("ready")
        print(f"ready: directory={self.directory} UDID={self.udid} runToken={self.run_token}", flush=True)
        while not self.stopping():
            now = time.monotonic()
            if now >= self.deadline:
                raise CaptureFailure(f"capture driver total watchdog expired after {self.max_duration:g} seconds")
            if now - self.last_request >= self.idle_timeout:
                raise CaptureFailure(f"capture driver idle watchdog expired after {self.idle_timeout:g} seconds")
            for path in sorted(self.directory.glob("*.request.json")):
                if self.stopping():
                    break
                token = path.name.removesuffix(".request.json")
                if not (self.directory / (token + ".response.json")).exists():
                    self.capture(path)
                    self.last_request = time.monotonic()
            self.stop.wait(0.02)  # Bounded mailbox polling; does not sleep or alter the app.
        self.state("stopped")


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--directory", type=Path, required=True, help="fresh absolute shared mailbox/evidence directory")
    parser.add_argument("--udid", required=True, help="exact allocated Simulator UUID (never 'booted')")
    parser.add_argument("--capture-timeout", type=positive_seconds, default=10, help="per-simctl watchdog seconds (default 10)")
    parser.add_argument("--idle-timeout", type=positive_seconds, default=300, help="idle watchdog seconds (default 300)")
    parser.add_argument("--max-duration", type=positive_seconds, default=1800, help="total watchdog seconds (default 1800)")
    arguments = parser.parse_args()
    if not arguments.directory.is_absolute():
        parser.error("--directory must be absolute and match TEST_RUNNER_VIDEO_COMPONENTS_CAPTURE_DIRECTORY")
    directory = arguments.directory.resolve()
    driver = Driver(directory, arguments.udid, arguments.capture_timeout, arguments.idle_timeout, arguments.max_duration)
    directory.mkdir(parents=True, exist_ok=True)
    if any(directory.iterdir()):
        raise CaptureFailure("capture directory must be fresh/empty; existing evidence is never overwritten")
    lock = directory / "driver.lock"
    with lock.open("x") as output:
        output.write(str(os.getpid()) + "\n")
    try:
        signal.signal(signal.SIGTERM, driver.handle_signal)
        signal.signal(signal.SIGINT, driver.handle_signal)
        try:
            driver.watch()
        except (OSError, ValueError, TypeError, CaptureFailure, subprocess.SubprocessError) as error:
            driver.state("failed", str(error))
            print("capture driver failed: " + str(error), file=sys.stderr, flush=True)
            return 1
        return 0
    finally:
        lock.unlink(missing_ok=True)


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (OSError, ValueError, CaptureFailure) as error:
        sys.exit("capture driver failed: " + str(error))
