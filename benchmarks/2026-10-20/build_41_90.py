"""Build pinned current submissions 41–90 in isolated native ARM64 containers.

Run as ``python3 build_41_90.py [PR ...]``. Toolchain setup is recorded in
runtime-scripts/pr<id>.sh, without changing submitted application sources.
"""
import concurrent.futures
import threading
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parent
STATUS = ROOT / "build-status-41-90.json"
BASE = "twelve-unified:2026-10-07"
PATH = "/usr/local/go/bin:/opt/twelve-rust/cargo/bin:/opt/twelve-go-1.27.1/bin:/opt/ruby/bin:/usr/local/bin:/usr/bin:/bin"
LOCK = threading.Lock()
ENV = ["env", f"PATH={PATH}", "RUSTUP_HOME=/opt/twelve-rust/rustup",
       "CARGO_BUILD_JOBS=2", "DOTNET_CLI_HOME=/home/bench",
       "DOTNET_CLI_TELEMETRY_OPTOUT=1", "DOTNET_SKIP_FIRST_TIME_EXPERIENCE=1", "V_MACOS_V3_NO_FALLBACK=1"]


def docker(args, log=None, timeout=600, check=True):
    command = ["docker", *args]
    if log:
        with (ROOT / "logs" / log).open("a") as stream:
            stream.write("\n$ " + " ".join(command) + "\n")
            stream.flush()
            try:
                result = subprocess.run(command, stdout=stream,
                                        stderr=subprocess.STDOUT, timeout=timeout)
                code = result.returncode
            except subprocess.TimeoutExpired:
                stream.write(f"\nBUILD TIMEOUT after {timeout}s\n")
                code = 124
    else:
        result = subprocess.run(command, stdout=subprocess.PIPE,
                                stderr=subprocess.STDOUT, text=True, timeout=timeout)
        code = result.returncode
        if check and code:
            raise RuntimeError(result.stdout)
        return result.stdout.strip()
    if check and code:
        raise RuntimeError(f"Command failed with {code}: {log}")
    return code


def save(status):
    with LOCK:
        temporary = STATUS.with_suffix(".tmp")
        temporary.write_text(json.dumps(status, indent=2) + "\n")
        temporary.replace(STATUS)


def build(candidate, status):
    pr = candidate["pr"]
    source = ROOT / "sources" / f"pr{pr}"
    if not (source / "build.sh").is_file():
        status[str(pr)] = {"pr":pr,"commit":candidate["commit"],"state":"missing_build_script","exit_code":None,"reason":"Submitted snapshot has no required build.sh."}
        save(status)
        print(f"PR {pr}: missing build.sh", flush=True)
        return
    expected=json.loads((ROOT / "archives" / f"pr{pr}-sha256.json").read_text())
    assert all((source/n).is_file() and hashlib.sha256((source/n).read_bytes()).hexdigest()==v for n,v in expected.items()), f"PR{pr} source hashes differ"
    container = f"twelve-current-build-pr{pr}"
    image = f"twelve-current-pr{pr}:2026-10-20"
    log = f"build-pr{pr}.log"
    (ROOT / "logs" / log).write_text("")
    started = time.monotonic()
    record = {"pr": pr, "commit": candidate["commit"], "base": BASE,
              "architecture": "linux/arm64", "image": image, "source_hashes_verified": True, "state":"building", "log":f"logs/{log}",
              "seccomp_profile_sha256":hashlib.sha256((ROOT/"seccomp-io-uring.json").read_bytes()).hexdigest(),
              "runtime_integrity": "official checksums or pinned apt packages; see setup log" if pr!=43 else "Swift archive from official HTTPS release; upstream installer has no checksum",
              "started_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())}
    status[str(pr)] = record
    save(status)
    if candidate.get("folder", "").startswith("asm-"):
        record.update(state="unsupported_architecture", exit_code=None,
                      reason="Submission requires x86-64 assembly; native host is ARM64.")
        save(status)
        print(f"PR {pr}: x86-64 assembly unsupported", flush=True)
        return
    docker(["rm", "-f", container], check=False)
    try:
        docker(["run", "-d", "--name", container, "--cpus", "2",
                "--memory", "6g" if pr in (69,70) else "3g", "--memory-swap", "6g" if pr in (69,70) else "3g", "--security-opt", f"seccomp={ROOT / 'seccomp-io-uring.json'}",
                "--mount", f"type=bind,src={ROOT},dst=/evidence,readonly",
                BASE, "sleep", "infinity"])
        stage = (f"set -e; rm -rf /suite/sources; mkdir -p /suite/sources; "
                 f"cp -a /evidence/sources/pr{pr} /suite/sources/; "
                 "cp /evidence/manifest.json /suite/manifest.json; cp /evidence/schema.sql /suite/schema.sql; "
                 "chown -R bench:bench /suite/sources")
        docker(["exec", container, "bash", "-c", stage], log)
        setup = ROOT / "runtime-scripts" / f"pr{pr}.sh"
        if setup.exists():
            record["runtime_setup"] = f"runtime-scripts/pr{pr}.sh"
            docker(["exec", container, "bash", f"/evidence/runtime-scripts/pr{pr}.sh"],
                   log, timeout=900)
        command = ROOT / "runtime-scripts" / f"pr{pr}-build.sh"
        build_path = f"/evidence/runtime-scripts/pr{pr}-build.sh" if command.exists() else f"/suite/sources/pr{pr}/build.sh"
        if command.exists():
            record["build_adapter"] = f"runtime-scripts/pr{pr}-build.sh"
        code = docker(["exec", container, "runuser", "-u", "bench", "--",
                       *ENV, "bash", build_path], log, timeout=600, check=False)
        record["exit_code"] = code
        if code:
            record["state"] = "build_failed"
            return
        if (candidate.get("folder") or "").startswith("go-"):
            docker(["exec",container,"/usr/local/go/bin/go","version","-m",f"/suite/sources/pr{pr}/bin/server"],log,check=False)
        # Application runtime packages (venvs, node_modules, gems) are retained.
        # The source image's unrelated submissions and caches need not persist.
        cleanup = ("rm -f /usr/local/bin/nproc; rm -rf /tmp/* /root/.cache /root/.cargo/registry "
                   "/home/bench/.cache /home/bench/.cargo/registry "
                   "/home/bench/.npm/_cacache /var/lib/apt/lists/* "
                   "/var/cache/apt/archives/*.deb; "
                   "find /suite/sources -type d -path '*/target/release/incremental' -prune -exec rm -rf {} +")
        docker(["exec", container, "bash", "-c", cleanup], log)
        record["image_id"] = docker(["commit", container, image], timeout=300)
        record["state"] = "built"
    except Exception as exc:
        record.update(state="setup_failed", error=str(exc))
    finally:
        if record.get("state") in ("build_failed","setup_failed"):
            record["failure_tail"]=(ROOT/"logs"/log).read_text()[-5000:]
        record["elapsed_s"] = round(time.monotonic() - started, 2)
        record["finished_at"] = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
        if pr in (69,70) and record.get("state") in ("setup_failed","build_failed"):
            record["retained_container"]=container
        else:
            docker(["rm", "-f", container], check=False)
        save(status)
        print(f"PR {pr}: {record['state']} ({record['elapsed_s']}s)", flush=True)


def main():
    manifest = json.loads((ROOT / "manifest.json").read_text())
    candidates = manifest if isinstance(manifest, list) else manifest["candidates"]
    requested = {int(value) for value in sys.argv[1:]}
    status = json.loads(STATUS.read_text()) if STATUS.exists() else {}
    pending=[]
    for candidate in sorted(candidates, key=lambda entry: ({71:0,43:1,53:2}.get(entry["pr"],3), entry["pr"])):
        pr = candidate["pr"]
        if not 41 <= pr <= 90 or (requested and pr not in requested):
            continue
        if not requested and status.get(str(pr), {}).get("state") in ("built", "unsupported_architecture", "missing_build_script", "build_failed", "setup_failed") and not (pr==56 and status.get(str(pr),{}).get("state")=="build_failed"):
            continue
        pending.append(candidate)
    with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
        list(pool.map(lambda candidate: build(candidate,status), pending))


if __name__ == "__main__":
    main()
