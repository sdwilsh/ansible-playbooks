#!/usr/bin/env python3
"""Run the `sif` image under the security context of the pod.

Give each container a read-only root, uid 1000, no new privileges, no
capability, and a world-writable `/run`.  The image holds the scripts and
the `S6_` settings, so each container takes the model list and the address
only.  Run each probe through `exec`, which gives the probe the `PATH` of
the image.

Usage: e2e.py <image-tag>
"""

import os
import subprocess
import sys
import tempfile
import time
import traceback
from collections.abc import Callable
from pathlib import Path

Result = subprocess.CompletedProcess[str]
Process = dict[str, str]

RUNTIME: str = os.environ.get("CONTAINER_RUNTIME", "docker")
TEST_DIR: Path = Path(__file__).resolve().parent
FIXTURES_DIR: Path = TEST_DIR / "fixtures"
SCRIPTS_DIR = "/usr/local/bin"

# The suite must make this many results.  A scenario that stops early makes
# fewer.
EXPECTED_ASSERTIONS = 30


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


def runtime(*arguments: str, timeout: int = 120) -> Result:
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


def fixture(name: str) -> str:
    return (FIXTURES_DIR / name).read_text().rstrip("\n")


class Harness:
    def __init__(self, image: str, work_dir: Path) -> None:
        self.image: str = image
        self.containers: list[str] = []
        self.models: Path = work_dir / "models"
        self.run_dir: Path = work_dir / "run"

        # The stub does not read a model.
        self.models.mkdir()
        for shard in (
            "alpha-00001-of-00001.gguf",
            "beta-00001-of-00002.gguf",
            "beta-00002-of-00002.gguf",
        ):
            (self.models / shard).touch()

        # This directory takes the place of the `emptyDir` on `/run`.  It
        # lives through a container restart.  The kubelet gives that volume
        # to root, and s6 stops when `/run` belongs to a third uid, so a
        # container with root makes root the owner here as well.
        self.run_dir.mkdir()
        self.run_dir.chmod(0o777)
        result = self.as_root("chown 0:0 /mnt && chmod 0777 /mnt")
        if result.returncode != 0:
            raise RuntimeError(f"cannot give /run to root: {result.stderr}")

    def common_arguments(self) -> list[str]:
        return [
            "--cap-drop=ALL",
            "--read-only",
            "--security-opt", "no-new-privileges",
            "--user", "1000:1000",
            "--tmpfs", "/tmp:rw,size=64m",
            "-v", f"{TEST_DIR}:/test:ro,Z",
            "-v", f"{TEST_DIR}/stub-llama-server.sh:/app/llama-server:ro,Z",
            "-v", f"{self.models}:/models:ro,Z",
        ]

    def start(self, name: str, *extra: str, host_run: bool = False) -> None:
        runtime("rm", "-f", name)
        self.containers.append(name)
        run_mount = (
            ["-v", f"{self.run_dir}:/run:Z"]
            if host_run
            # The pod gives `/run` a 16Mi `emptyDir` on memory.
            else ["--tmpfs", "/run:rw,exec,mode=0777,size=16m"]
        )
        result = runtime(
            "run", "-d", "--name", name,
            *self.common_arguments(), *run_mount, *extra, self.image,
        )
        if result.returncode != 0:
            raise RuntimeError(f"{RUNTIME} run failed: {result.stderr}")

    def logs(self, name: str) -> tuple[str, str]:
        result = runtime("logs", name)
        return result.stdout, result.stderr

    def exit_code(self, name: str) -> str:
        return runtime(
            "inspect", name, "--format", "{{.State.ExitCode}}"
        ).stdout.strip()

    def stopped(self, name: str) -> bool:
        state = runtime(
            "inspect", name, "--format", "{{.State.Running}}"
        ).stdout.strip()
        return state == "false"

    def processes(self, name: str) -> list[Process]:
        """Read the process table in the container, not on the host."""
        result = runtime(
            "exec", name, "ps", "-eo", "uid,pid,ppid,args", "--no-headers"
        )
        rows: list[Process] = []
        for line in result.stdout.splitlines():
            fields = line.split(None, 3)
            if len(fields) == 4:
                rows.append(
                    {
                        "uid": fields[0],
                        "pid": fields[1],
                        "ppid": fields[2],
                        "args": fields[3].strip(),
                    }
                )
        return rows

    def supervised(
        self, name: str, alias: str
    ) -> tuple[str | None, str | None]:
        """Give the pid and the uid of the child of `s6-supervise <alias>`."""
        rows = self.processes(name)
        parents = [r["pid"] for r in rows if r["args"] == f"s6-supervise {alias}"]
        if not parents:
            return None, None
        for row in rows:
            if row["ppid"] == parents[0]:
                return row["pid"], row["uid"]
        return None, None

    def probe(
        self, name: str, script: str, models: str | None = None
    ) -> Result:
        environment = [] if models is None else ["-e", f"MODELS={models}"]
        return runtime("exec", *environment, name, f"{SCRIPTS_DIR}/{script}")

    def as_root(self, command: str) -> Result:
        """Run a command as root, with the run directory on `/mnt`."""
        return runtime(
            "run", "--rm", "--user", "0:0",
            "-v", f"{self.run_dir}:/mnt:Z",
            "--entrypoint", "/bin/sh", self.image,
            "-c", command,
        )

    def clean(self) -> None:
        for name in self.containers:
            runtime("rm", "-f", name)
        # Root owns the tree, and the user of this script does not.
        self.as_root("rm -rf /mnt/..?* /mnt/.[!.]* /mnt/*")


def two_models(report: Report, harness: Harness) -> None:
    name = "two-models"
    harness.start(
        name, "-e", "POD_IP=127.0.0.1", "-e", f"MODELS={fixture('two-models')}"
    )

    ready = wait_for(
        30, lambda: harness.probe(name, "check-servers.sh").returncode == 0
    )
    report.check(
        "each model server answers /health", ready, harness.logs(name)[1]
    )

    # A truncated argument list gives `llama-server` the defaults of the
    # image.
    stdout = harness.logs(name)[0]
    for alias, shard, port in (
        ("alpha", "alpha-00001-of-00001.gguf", "8080"),
        ("beta", "beta-00001-of-00002.gguf", "8081"),
    ):
        expected = (
            f"[{alias}] starting -m /models/{shard} -a {alias}"
            f" --host 127.0.0.1 --port {port} --ctx-size 4096"
            " --metrics -fa on -ngl 999 --parallel 1"
        )
        report.check(
            f"{alias} starts with the whole argument list",
            expected in stdout,
            f"want: {expected}\ngot:\n{stdout}",
        )

    before: dict[str, str | None] = {}
    for alias in ("alpha", "beta"):
        pid, uid = harness.supervised(name, alias)
        before[alias] = pid
        report.check(
            f"s6-supervise owns {alias} as uid 1000",
            pid is not None and uid == "1000",
            harness.processes(name),
        )

    runtime("exec", name, "sh", "-c", f"kill -9 {before['alpha']}")
    report.check(
        "s6 starts alpha again after a kill",
        wait_for(
            5,
            lambda: harness.supervised(name, "alpha")[0]
            not in (None, before["alpha"]),
        ),
        harness.processes(name),
    )
    report.check(
        "beta keeps its pid while alpha restarts",
        harness.supervised(name, "beta")[0] == before["beta"],
        harness.processes(name),
    )

    path = runtime("exec", name, "printenv", "PATH").stdout.strip()
    report.check(
        "an exec probe gets /command on PATH", path.startswith("/command:"), path
    )
    for script in ("check-servers.sh", "check-supervisor.sh"):
        result = harness.probe(name, script)
        report.check(f"{script} exits 0", result.returncode == 0, result.stderr)

    # `s6-svc -d` holds a server down.  Liveness must stay green.
    runtime("exec", name, "/command/s6-svc", "-d", "/run/service/beta")
    down = wait_for(
        10,
        lambda: runtime(
            "exec", name, "/command/s6-svstat", "-o", "up", "/run/service/beta"
        ).stdout.strip()
        == "false",
    )
    report.check("s6-svc -d holds beta down", down)
    supervisor = harness.probe(name, "check-supervisor.sh")
    report.check(
        "check-supervisor.sh exits 0 while beta is down",
        supervisor.returncode == 0,
        supervisor.stdout + supervisor.stderr,
    )
    servers = harness.probe(name, "check-servers.sh")
    report.check(
        "check-servers.sh fails while beta is down", servers.returncode != 0
    )
    runtime("exec", name, "/command/s6-svc", "-u", "/run/service/beta")
    report.check(
        "beta answers again after s6-svc -u",
        wait_for(
            30, lambda: harness.probe(name, "check-servers.sh").returncode == 0
        ),
        harness.logs(name)[1],
    )

    dead_port = harness.probe(
        name, "check-servers.sh", models="ghost|url|shard|9099|4096"
    )
    report.check(
        "check-servers.sh fails for a port with no server",
        dead_port.returncode != 0,
    )
    ghost = harness.probe(
        name, "check-supervisor.sh", models="ghost|url|shard|8080|4096"
    )
    report.check(
        "check-supervisor.sh fails for an alias with no service",
        ghost.returncode != 0,
    )

    stdout = harness.logs(name)[0]
    unprefixed = [
        line
        for line in stdout.splitlines()
        if not line.startswith(("[alpha] ", "[beta] "))
    ]
    report.check(
        "every line of a server carries its own prefix",
        not unprefixed,
        "\n".join(unprefixed),
    )

    runtime("stop", "-t", "10", name)
    report.check(
        "a stop signal ends the container with status 0",
        harness.exit_code(name) == "0",
        harness.logs(name)[1],
    )

    stderr = harness.logs(name)[1]
    report.check(
        "s6 accepts the world-writable /run", "IS WORLD WRITABLE" in stderr, stderr
    )
    report.check("no service reports a fatal", "fatal:" not in stderr, stderr)


def hook_failure(
    report: Report, harness: Harness, name: str, message: str, *extra: str
) -> None:
    """Check that a fault in a record stops the container from the hook."""
    harness.start(name, *extra)
    stopped = wait_for(30, lambda: harness.stopped(name))
    stderr = harness.logs(name)[1]
    report.check(
        f"{name} stops the container from the hook",
        stopped
        and harness.exit_code(name) != "0"
        and "rc.init: fatal: hook" in stderr
        and message in stderr,
        stderr,
    )


def negatives(report: Report, harness: Harness) -> None:
    hook_failure(
        report, harness, "duplicate-port", "port 8080 belongs to two records",
        "-e", "POD_IP=127.0.0.1", "-e", f"MODELS={fixture('duplicate-port')}",
    )
    hook_failure(
        report, harness, "empty-models", "MODELS has no value",
        "-e", "POD_IP=127.0.0.1", "-e", "MODELS=",
    )
    hook_failure(
        report, harness, "no-pod-ip", "POD_IP has no value",
        "-e", f"MODELS={fixture('two-models')}",
    )
    # A second source directory holds a service with a `type` that s6 rejects.
    hook_failure(
        report, harness, "bad-type",
        "invalid /etc/s6-overlay/s6-rc.d/bad-service/type",
        "-e", "POD_IP=127.0.0.1", "-e", f"MODELS={fixture('two-models')}",
        "-v", f"{FIXTURES_DIR}/bad-type:/etc/s6-overlay/s6-rc.d:ro,Z",
    )
    hook_failure(
        report, harness, "bad-alias", "has a character that s6 rejects",
        "-e", "POD_IP=127.0.0.1", "-e", f"MODELS={fixture('bad-alias')}",
    )
    hook_failure(
        report, harness, "reserved-alias", "is a name that s6-overlay uses",
        "-e", "POD_IP=127.0.0.1", "-e", f"MODELS={fixture('reserved-alias')}",
    )
    # "8080" and "08080" are one port with two spellings.
    hook_failure(
        report, harness, "leading-zero-port", "has a leading zero",
        "-e", "POD_IP=127.0.0.1",
        "-e", f"MODELS={fixture('leading-zero-port')}",
    )
    hook_failure(
        report, harness, "bad-context", "is not a number",
        "-e", "POD_IP=127.0.0.1", "-e", f"MODELS={fixture('bad-context')}",
    )


def missing_user2(report: Report, harness: Harness) -> None:
    name = "missing-user2"
    harness.start(
        name,
        "-e", "POD_IP=127.0.0.1",
        "-e", "S6_STAGE2_HOOK=/test/hook-drop-user2.sh",
        "-e", f"MODELS={fixture('two-models')}",
    )
    time.sleep(10)
    stderr = harness.logs(name)[1]
    supervised = any(
        row["args"] == "s6-supervise alpha" for row in harness.processes(name)
    )
    report.check(
        "a tree without user2 leaves the container with no service",
        "undefined service name user2" in stderr and not supervised,
        stderr,
    )


def stale_tree(report: Report, harness: Harness) -> None:
    harness.start(
        "stale-first", "-e", "POD_IP=127.0.0.1",
        "-e", f"MODELS={fixture('two-models')}", host_run=True,
    )
    first = wait_for(
        30,
        lambda: harness.probe("stale-first", "check-servers.sh").returncode == 0,
    )
    if not first:
        report.check("the first boot starts", False, harness.logs("stale-first")[1])
        return
    runtime("stop", "-t", "10", "stale-first")

    harness.start(
        "stale-second", "-e", "POD_IP=127.0.0.1",
        "-e", f"MODELS={fixture('one-model')}", host_run=True,
    )
    second = wait_for(
        30,
        lambda: harness.probe("stale-second", "check-servers.sh").returncode == 0,
    )
    if not second:
        report.check(
            "the second boot starts", False, harness.logs("stale-second")[1]
        )
        return
    rows = [row["args"] for row in harness.processes("stale-second")]
    report.check(
        "a second boot drops the model that MODELS no longer holds",
        "s6-supervise alpha" in rows and "s6-supervise beta" not in rows,
        "\n".join(rows),
    )


def main() -> int:
    if len(sys.argv) != 2:
        print("Usage: e2e.py <image-tag>", file=sys.stderr)
        return 2
    image = sys.argv[1]

    scenarios: tuple[tuple[str, Callable[[Report, Harness], None]], ...] = (
        ("two-models", two_models),
        ("negatives", negatives),
        ("missing-user2", missing_user2),
        ("stale-tree", stale_tree),
    )

    report = Report()
    with tempfile.TemporaryDirectory() as work:
        harness = Harness(image, Path(work))
        try:
            for name, scenario in scenarios:
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
