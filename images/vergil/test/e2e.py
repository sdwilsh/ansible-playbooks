#!/usr/bin/env python3
"""Run the `vergil` image under the security context of the pod.

Each container gets uid 1000, no new privileges and no capability.  Most get
a read-only root.  The `flm` wrapper makes a directory and a symbolic link at
each start, and a read-only root refuses the link without a message.  The
tarball holds a complete multiarch mirror, so the wrapper skips each link.

`check-transcription.sh` runs against a stub server.  The real server answers
200 with a body of `null` when it loads no ASR model, and a status check does
not find that state.

Usage: e2e.py <image-tag>
"""

import contextlib
import os
import socket
import subprocess
import sys
import time
import traceback
from collections.abc import Callable, Iterator, Sequence
from pathlib import Path

RUNTIME = os.environ.get("CONTAINER_RUNTIME", "docker")
TEST_DIR = Path(__file__).resolve().parent
STUB_SERVER = TEST_DIR / "stub-flm-server.py"
# `check-transcription.sh` holds this port.
SERVER_PORT = 8080
PREFIX = "/opt/vergil"
MIRROR_DIR = f"{PREFIX}/lib/x86_64-linux-gnu"
PROBE_SCRIPT = f"{PREFIX}/check-transcription.sh"
PROBE_WAV = f"{PREFIX}/probe.wav"
PROBE_SHA256 = "59dfb9a4acb36fe2a2affc14bacbee2920ff435cb13cc314a08c13f66ba7860e"
PROBE_BYTES = "352078"
# The pod gives `/models` a volume.  The server stops at that path before it
# opens the device when the path is absent.
MODEL_MOUNT = ["--tmpfs", "/models:rw,size=16m"]

# A scenario that stops early makes no result, and a suite that only counts
# failures then reports success.  Raise this number with each assertion.
EXPECTED_ASSERTIONS = 18


class Report:
    """Collect a named result for each assertion, and never stop early."""

    def __init__(self) -> None:
        self.failures: int = 0
        self.total: int = 0

    def check(self, name: str, condition: bool, detail: object = "") -> None:
        self.total += 1
        if condition:
            print(f"PASS: {name}", flush=True)
            return
        print(f"FAIL: {name}", flush=True)
        for line in str(detail).rstrip().splitlines():
            print(f"    {line}", flush=True)
        self.failures += 1


def runtime(
    *arguments: str, timeout: float = 120
) -> subprocess.CompletedProcess[str]:
    """Run the container runtime.  Give the caller the whole result."""
    return subprocess.run(
        [RUNTIME, *arguments],
        capture_output=True,
        text=True,
        timeout=timeout,
        check=False,
    )


def wait_for(seconds: int, condition: Callable[[], bool]) -> bool:
    for _ in range(seconds):
        if condition():
            return True
        time.sleep(1)
    return condition()


def port_answers(port: int) -> bool:
    with socket.socket() as probe:
        probe.settimeout(1)
        return probe.connect_ex(("127.0.0.1", port)) == 0


@contextlib.contextmanager
def stub_server(mode: str) -> Iterator[None]:
    """Hold a stub server on the port that the probe reads."""
    process = subprocess.Popen(
        [sys.executable, str(STUB_SERVER), mode, str(SERVER_PORT)]
    )
    try:
        wait_for(15, lambda: port_answers(SERVER_PORT))
        yield
    finally:
        process.terminate()
        process.wait(timeout=10)


def changed_paths(name: str) -> list[str]:
    """Give the paths of the root that a container changed."""
    return sorted(runtime("diff", name).stdout.splitlines())


class Harness:
    def __init__(self, image: str) -> None:
        self.image: str = image
        self.containers: list[str] = []
        self.server: str = "vergil-server"

    def security_context(self, read_only: bool = True) -> list[str]:
        # Keep each option next to its value.
        options = [
            "--cap-drop=ALL",
            "--security-opt", "no-new-privileges",
            "--user", "1000:1000",
            "--tmpfs", "/tmp:rw,size=64m",
        ]
        if read_only:
            options.append("--read-only")
        return options

    def run(
        self, *arguments: str, timeout: float = 120
    ) -> subprocess.CompletedProcess[str]:
        """Run the entrypoint once under the security context."""
        return runtime(
            "run", "--rm", *self.security_context(), self.image, *arguments,
            timeout=timeout,
        )

    def start(
        self,
        name: str,
        *arguments: str,
        extra: Sequence[str] = (),
        read_only: bool = True,
    ) -> None:
        runtime("rm", "-f", name)
        self.containers.append(name)
        result = runtime(
            "run", "-d", "--name", name,
            *self.security_context(read_only=read_only), *extra,
            self.image, *arguments,
        )
        if result.returncode != 0:
            raise RuntimeError(f"{RUNTIME} run failed: {result.stderr}")

    def logs(self, name: str) -> str:
        result = runtime("logs", name)
        return result.stdout + result.stderr

    def exit_code(self, name: str) -> str:
        return runtime(
            "inspect", name, "--format", "{{.State.ExitCode}}"
        ).stdout.strip()

    def stopped(self, name: str) -> bool:
        # A container that is absent gives an empty answer.  Stop the
        # scenario, because an empty answer otherwise reads as "not stopped".
        result = runtime("inspect", name, "--format", "{{.State.Running}}")
        if result.returncode != 0:
            raise RuntimeError(f"{RUNTIME} inspect failed: {result.stderr}")
        return result.stdout.strip() == "false"

    def shell(
        self, script: str, *extra: str, timeout: float = 120
    ) -> subprocess.CompletedProcess[str]:
        """Run a script in the image with a writable root and uid 0."""
        return runtime(
            "run", "--rm", "--entrypoint", "/bin/bash", *extra,
            self.image, "-c", script, timeout=timeout,
        )

    def clean(self) -> None:
        for name in self.containers:
            runtime("rm", "-f", name)


def security_context(report: Report, harness: Harness) -> None:
    """The pod gives the container a read-only root and uid 1000."""
    entrypoint = runtime(
        "inspect", harness.image, "--format", "{{json .Config.Entrypoint}}"
    ).stdout.strip()
    report.check(
        "the image starts flm", entrypoint == f'["{PREFIX}/flm"]', entrypoint
    )

    # The `version` command gives status 0.  The `--version` option does not.
    version = harness.run("version")
    output = version.stdout + version.stderr
    report.check(
        "the wrapper reaches flm-real on a read-only root",
        version.returncode == 0 and version.stdout.strip() != "",
        output,
    )
    report.check(
        "a start reports no write fault", "Read-only file system" not in output,
        output,
    )

    # The probe scenario needs a container to `exec` in.  A `sleep` holds one
    # open, and host networking reaches the stub server.
    harness.start(
        harness.server,
        "-c", "exec sleep 600",
        extra=["--entrypoint", "/bin/bash", "--network", "host"],
    )
    time.sleep(5)
    report.check(
        "the container stays up under the security context",
        not harness.stopped(harness.server),
        harness.logs(harness.server),
    )


def multiarch_mirror(report: Report, harness: Harness) -> None:
    """A start must change no file of the mirror, even with a writable root."""
    listing = f"find {MIRROR_DIR} -printf '%y %p %l %s %T@\\n' | sort"
    result = harness.shell(
        f"{listing} > /tmp/before"
        f" && {PREFIX}/flm version > /dev/null"
        f" && {listing} > /tmp/after"
        " && diff /tmp/before /tmp/after"
    )
    report.check(
        "a start changes no file of the multiarch mirror",
        result.returncode == 0,
        result.stdout + result.stderr,
    )


def probe_clip(report: Report, harness: Harness) -> None:
    """The clip must stay the clip that each measurement used."""
    result = harness.shell(
        f"head -c 4 {PROBE_WAV}; echo;"
        f" dd if={PROBE_WAV} bs=1 skip=8 count=4 2>/dev/null; echo;"
        f" sha256sum {PROBE_WAV} | cut -d' ' -f1;"
        f" stat -c %s {PROBE_WAV}"
    )
    lines = result.stdout.splitlines()
    report.check(
        "the image holds the probe clip",
        result.returncode == 0 and len(lines) == 4 and lines[3] == PROBE_BYTES,
        result.stdout + result.stderr,
    )
    if len(lines) != 4:
        return
    report.check("the clip starts with RIFF", lines[0] == "RIFF", lines[0])
    report.check("the clip holds WAVE", lines[1] == "WAVE", lines[1])
    report.check("the clip hashes to the pin", lines[2] == PROBE_SHA256, lines[2])


def transcription_probe(report: Report, harness: Harness) -> None:
    """`jq -e` must reject each body that holds no transcript."""
    no_address = runtime("exec", harness.server, PROBE_SCRIPT)
    report.check(
        "the probe fails with no POD_IP",
        no_address.returncode != 0 and "POD_IP has no value" in no_address.stderr,
        no_address.stdout + no_address.stderr,
    )

    # A real server answers `null` when it loads no ASR model.
    for mode, wanted, name in (
        ("text", 0, "a transcript gives success"),
        ("null", 1, "a body of null fails"),
        ("null-text", 1, "a text field of null fails"),
        ("empty-text", 1, "an empty text field fails"),
        ("error", 1, "a status of 500 fails"),
        ("stall", 1, "a stall past the timeout fails"),
    ):
        with stub_server(mode):
            result = runtime(
                "exec", "-e", "POD_IP=127.0.0.1", harness.server, PROBE_SCRIPT,
                timeout=60,
            )
        report.check(
            name, (result.returncode == 0) == (wanted == 0),
            f"exit {result.returncode}\n{result.stdout}{result.stderr}",
        )


def serve_without_device(report: Report, harness: Harness) -> None:
    """A node with no NPU device must not leave the server in a stall."""
    name = "vergil-no-device"
    harness.start(name, "serve", "--asr", "1", extra=MODEL_MOUNT)
    report.check(
        "flm serve stops with no NPU device",
        wait_for(30, lambda: harness.stopped(name))
        and harness.exit_code(name) != "0",
        harness.logs(name),
    )

    # A writable root records a write to the image layer.  A write to a tmpfs
    # does not appear.  The runtime binds some files of `/etc`, and an idle
    # container names those.
    idle = "vergil-idle"
    harness.start(
        idle, "-c", "exec sleep 120",
        extra=[*MODEL_MOUNT, "--entrypoint", "/bin/bash"], read_only=False,
    )
    writable = "vergil-writable"
    harness.start(writable, "serve", "--asr", "1", extra=MODEL_MOUNT,
                  read_only=False)
    wait_for(30, lambda: harness.stopped(writable))
    changes = changed_paths(writable)
    report.check(
        "flm serve writes no path of the root",
        changes == changed_paths(idle),
        "\n".join(changes),
    )


def main() -> int:
    if len(sys.argv) != 2:
        print("Usage: e2e.py <image-tag>", file=sys.stderr)
        return 2
    image = sys.argv[1]

    report = Report()
    harness = Harness(image)
    try:
        for name, scenario in (
            ("security-context", security_context),
            ("multiarch-mirror", multiarch_mirror),
            ("probe-clip", probe_clip),
            ("transcription-probe", transcription_probe),
            ("serve-without-device", serve_without_device),
        ):
            print(f"=== {name} ===", flush=True)
            try:
                scenario(report, harness)
            except Exception:
                report.check(
                    f"{name} runs to the end", False, traceback.format_exc()
                )
    finally:
        harness.clean()

    if report.total == EXPECTED_ASSERTIONS:
        print(f"PASS: the suite makes {EXPECTED_ASSERTIONS} assertions")
    else:
        print(
            f"FAIL: the suite makes {EXPECTED_ASSERTIONS} assertions,"
            f" but it made {report.total}"
        )
        report.failures += 1

    if report.failures:
        print(f"{report.failures} assertion(s) failed")
        return 1
    print(f"All {report.total} assertions passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
