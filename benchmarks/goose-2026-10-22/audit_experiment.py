"""Independent, offline audit of both retained Goose/Rust experiment batches.

No imports from the analysis/controller, Docker calls, network requests or loads.
The only output file is audit-experiment.json beside this script. A final pass
requires all 20 measured attempts, correctness evidence, and both published local
summaries. Missing confirmation evidence produces 'pending', never a final pass.
"""
import ast
import datetime as dt
import hashlib
import json
import math
import re
import statistics
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent
REPO = ROOT.parents[1]
SOCKETS = ("connect", "read", "write", "timeout")
ISSUES, PENDING = [], []


def require(condition, message):
    if not condition:
        ISSUES.append(message)
    return bool(condition)


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def canonical(value):
    return hashlib.sha256(json.dumps(value, sort_keys=True).encode()).hexdigest()


def load(path, default=None):
    if not path.is_file():
        PENDING.append(str(path.relative_to(ROOT)))
        return default
    return json.loads(path.read_text())


def close(a, b):
    return (type(a) in (int, float) and type(b) in (int, float)
            and math.isfinite(a) and math.isfinite(b)
            and math.isclose(a, b, rel_tol=1e-8, abs_tol=1e-6))


def raw_wrk(text):
    """Parse printed records independently, retaining rounded wrk rate/duration."""
    count, duration = re.search(r"(\d+) requests in ([\d.]+)s,", text).groups()
    rate = float(re.search(r"^Requests/sec:\s*([\d.]+)", text, re.M)[1])
    result = {"requests": int(count), "duration_s": float(duration), "rps": rate}
    if result["requests"] <= 0 or rate <= 0 or result["duration_s"] <= 0:
        raise ValueError("nonpositive raw request count/duration/rate")
    if abs(result["requests"] / rate - result["duration_s"]) > .0052:
        raise ValueError("printed count, rate and rounded duration disagree")
    for p in (50, 95, 99):
        m = re.search(r"^\s*" + str(p) + r"(?:\.0+)?%\s+([\d.]+)(us|ms|s)\s*$", text, re.M)
        result[f"p{p}_ms"] = float(m[1]) * {"us": .001, "ms": 1, "s": 1000}[m[2]]
    if not result["p50_ms"] <= result["p95_ms"] <= result["p99_ms"]:
        raise ValueError("unordered latency percentiles")
    m = re.search(r"Non-2xx or 3xx responses:\s*(\d+)", text)
    result["http_errors"] = int(m[1]) if m else 0
    m = re.search(r"Socket errors: connect (\d+), read (\d+), write (\d+), timeout (\d+)", text)
    result["socket_errors"] = dict(zip(SOCKETS, map(int, m.groups()) if m else [0] * 4))
    result["successful_rps"] = rate - result["http_errors"] / result["duration_s"]
    return result


def sample(value, label):
    processes = value["processes"]
    require(bool(processes), label + ": process samples missing")
    cpu = sum(v["cpu_s"] for v in processes.values())
    rss = sum(v["rss_kib"] for v in processes.values())
    require(close(cpu, value["cpu_s"]) and close(rss, value["rss_kib"]),
            label + ": sampled process totals disagree")
    require(all(close(v["cpu_s"], v["cpu_self_s"] + v["cpu_waited_children_s"])
                for v in processes.values()), label + ": CPU accounting disagrees")
    return cpu, rss


def database(record, label):
    dbs = [v["database_after"] for v in record.get("final", []) if "database_after" in v]
    db = dbs[0] if len(dbs) == 1 else {}
    good = (db.get("integrity") == "ok" and db.get("initial_post_count") == 500000
            and type(db.get("post_count")) is int and db["post_count"] > 500000
            and type(db.get("max_post_id")) is int and db["max_post_id"] > 500000
            and record.get("database_valid") is True)
    require(good, label + ": post-shutdown committed growth/integrity did not pass")
    return db


def identity(record, candidate, build, shared, label):
    expected = dict(case_id=candidate["case_id"], pr=candidate["pr"],
                    commit=candidate["commit"], image=build["image"],
                    source_sha256=candidate["source_sha256"], shared_hashes=shared,
                    image_id=build["image_id"])
    require(all(record.get(k) == v for k, v in expected.items()), label + ": source/image/fixture identity differs")
    require(record.get("fingerprint") == canonical(expected), label + ": fingerprint differs")
    service = record.get("service", {})
    require(service.get("ready") is True and service.get("source_sha256") == candidate["source_sha256"]
            and service.get("source_files_verified") == candidate["source_file_count"]
            and service.get("initial_post_count") == 500000 and service.get("nginx") is False,
            label + ": startup/source verification failed")
    require(not record.get("error"), label + ": controller error")
    state = record.get("container_state", {})
    require(not any(state.get(k) for k in ("OOMKilled", "Dead", "Error")), label + ": container error/OOM")
    actual = record.get("container_host_config", {})
    require(all(actual.get(k) == v for k, v in dict(CpusetCpus="0", NanoCpus=1000000000,
            Memory=2147483648, MemorySwap=2147483648).items()), label + ": unequal server resource limits")
    nofile = [v for v in actual.get("Ulimits", []) if v.get("Name") == "nofile"]
    require(len(nofile) == 1 and nofile[0].get("Soft") == nofile[0].get("Hard") == 65535,
            label + ": nofile differs")
    profiles = [json.loads(v.split("=", 1)[1]) for v in actual.get("SecurityOpt", []) if v.startswith("seccomp=")]
    require(profiles == [json.loads((ROOT / "seccomp-io-uring.json").read_text())],
            label + ": actual seccomp profile differs")
    return expected


def audit_batch(folder, expected_trials, selected_rounds):
    name = "initial" if folder == ROOT else "confirmation"
    manifest = load(folder / "manifest.json", [])
    builds = load(folder / "build-status.json", {})
    records = load(folder / "measurements.json", [])
    verifications = load(folder / "verification.json", [])
    env = load(folder / "environment-bench.json", {})
    shared = env.get("shared_hashes", {})
    result = {"expected_measurement_attempts": expected_trials * 2,
              "measurement_attempt_count": len(records), "verification_attempt_count": len(verifications),
              "warmup_attempt_count": sum(bool(v.get("warmup_output")) for v in records),
              "selected_rounds": selected_rounds,
              "excluded_rounds": [v for v in range(1, expected_trials + 1) if v not in selected_rounds],
              "rows": {}, "attempts": [], "verification_attempts": []}
    for rel, wanted in shared.items():
        p = folder / rel
        require(p.is_file() and digest(p) == wanted, f"{name}: shared file differs: {rel}")
    if not records:
        return result
    require(len(records) == expected_trials * 2, f"{name}: expected {expected_trials * 2} measured attempts, got {len(records)}")
    require(len(verifications) == 2, f"{name}: expected exactly two retained verification attempts")
    require({v.get("case_id") for v in manifest} == {"goose", "82"}, name + ": manifest cases differ")
    require({v.get("case_id") for v in records} == {"goose", "82"}, name + ": unexpected measured case")
    summary = load(folder / "summary.json", {})
    report = folder / "RESULT.md"
    if not report.is_file():
        PENDING.append(str(report.relative_to(ROOT)))
    for candidate in manifest:
        case = candidate["case_id"]
        label = f"{name}/{case}"
        build = builds.get(case)
        if not build:
            PENDING.append(label + ": build metadata")
            continue
        require(build.get("exit_code") == 0 and build.get("image_id")
                and build.get("proof", {}).get("binary_sha256"), label + ": missing successful binary/image proof")
        hashes = load(folder / candidate["source_hashes"], {})
        require(canonical(hashes) == candidate["source_sha256"] and len(hashes) == candidate["source_file_count"],
                label + ": manifest inventory fingerprint/count differs")
        inventory = load(folder / f"source-inventories/pr{case}.json", {}).get("files", {})
        for rel, wanted in hashes.items():
            p = folder / "sources" / f"pr{case}" / rel
            require(p.is_file() and digest(p) == wanted, label + ": frozen source differs: " + rel)
            require(inventory.get(rel, {}).get("sha256") == wanted, label + ": secondary inventory differs: " + rel)
        if case == "goose":
            edge = load(folder / "edge-checks.json", {})
            require(edge.get("image_id") == build["image_id"] and edge.get("source_app_sha256") == hashes.get("app.goose")
                    and edge.get("seed_sha256") == shared.get("seed/feed.db"), label + ": supplemental image/source/fixture identity differs")
            require(edge.get("passed_all") is True and len(edge.get("checks", [])) == 25
                    and all(v.get("passed") is True for v in edge.get("checks", [])), label + ": supplemental25checks failed")
        passing = []
        for i, v in enumerate(verifications):
            if v.get("case_id") != case:
                continue
            before_issues = len(ISSUES)
            tag = f"{label}/verify-attempt-{i}"
            identity(v, candidate, build, shared, tag)
            official = re.search(r"passed=(\d+) failed=(\d+)", v.get("output", ""))
            require(official is not None and official.groups() == ("42", "0")
                    and v.get("passed") == 42 and v.get("failed") == 0 and v.get("exit_code") == 0
                    and all(v.get(k) is True for k in ("official_passed_all", "passed_all")), tag + ": official 42/42 missing")
            semantic = json.loads(v.get("semantic_output", "{}"))
            require(semantic.get("passed_all") is True and semantic.get("checks")
                    and all(x.get("passed") is True for x in semantic["checks"])
                    and semantic.get("checks") == v.get("semantic", {}).get("checks")
                    and v.get("semantic", {}).get("exit_code") == 0, tag + ": raw semantic checks failed/differ")
            db = database(v, tag)
            result["verification_attempts"].append({"case_id": case, "attempt_index": i,
                "official_passed": 42 if official and official.groups() == ("42", "0") else None,
                "semantic_check_count": len(semantic.get("checks", [])), "database_after": db,
                "passed": len(ISSUES) == before_issues})
            if len(ISSUES) == before_issues:
                passing.append(v)
        computed = []
        case_records = [(i, v) for i, v in enumerate(records) if v.get("case_id") == case]
        require(len(case_records) == expected_trials and sorted(v.get("trial") for _, v in case_records)
                == list(range(1, expected_trials + 1)), label + ": missing/duplicate/unexpected trial numbers")
        for i, record in case_records:
            tag = f"{label}/attempt-{i}"
            identity(record, candidate, build, shared, tag)
            require(record.get("completed") is True and record.get("valid_duration") is True, tag + ": incomplete measurement")
            require(all(record.get("configuration", {}).get(k) == v for k, v in
                        dict(threads=2, connections=64, warmup_seconds=2, measurement_seconds=15).items()),
                    tag + ": workload configuration differs")
            m = raw_wrk(record.get("output", ""))
            warmup = raw_wrk(record.get("warmup_output", ""))
            require(14.5 <= m["duration_s"] <= 17 and 1.5 <= warmup["duration_s"] <= 4,
                    tag + ": raw duration outside expected interval")
            selected = record["trial"] in selected_rounds
            if selected:
                require(m["http_errors"] == 0 and not any(m["socket_errors"].values()), tag + ": selected measurement errors")
            else:
                expected_errors = {k: 58 if case == "82" and k == "timeout" else 0 for k in SOCKETS}
                require(name == "confirmation" and record["trial"] == 6 and m["http_errors"] == 0
                        and m["socket_errors"] == expected_errors, tag + ": excluded attempt differs from declared pair6 failure")
            require(warmup["http_errors"] == 0 and not any(warmup["socket_errors"].values()), tag + ": warmup errors")
            for k, value in m.items():
                require(record.get(k) == value if isinstance(value, dict) else close(record.get(k), value),
                        tag + ": stored raw metric differs: " + k)
            raw_log = folder / "logs" / f"bench-{case}-{record['trial']}.log"
            require(raw_log.is_file() and raw_log.read_text().strip() == record["output"].strip(),
                    tag + ": independent raw log differs/missing")
            bc, _ = sample(record["before"], tag + "/before")
            ac, rss = sample(record["after"], tag + "/after")
            elapsed = record["after"]["monotonic"] - record["before"]["monotonic"]
            require(elapsed > 0 and ac >= bc and rss > 0, tag + ": CPU/RSS sample interval invalid")
            m.update(cpu_percent=100 * (ac - bc) / elapsed, rss_mib=rss / 1024)
            require(close(record.get("cpu_percent"), m["cpu_percent"]) and close(record.get("rss_mib"), m["rss_mib"]),
                    tag + ": CPU/RSS derived totals differ")
            require(any(v.get("recorded_at", "") <= record.get("recorded_at", "") and
                        v.get("after", {}).get("monotonic", math.inf) <= record["before"]["monotonic"]
                        for v in passing), tag + ": no matching correctness gate completed before timing")
            db = database(record, tag)
            attempt = dict(case_id=case, trial=record["trial"], attempt_index=i, raw=m,
                           warmup=warmup, database_after=db, image_id=record["image_id"],
                           source_sha256=record["source_sha256"], selected=selected,
                           exclusion_reason=None if selected else "Entire pair6 excluded: Rust recorded58sockettimeouts")
            result["attempts"].append(attempt)
            if selected:
                computed.append(m)
        if not computed:
            continue
        row = {key: statistics.median(m[key] for m in computed) for key in
               ("rps", "successful_rps", "p50_ms", "p95_ms", "p99_ms", "rss_mib", "cpu_percent")}
        row.update(rps_min=min(m["rps"] for m in computed), rps_max=max(m["rps"] for m in computed),
                   http_errors=sum(m["http_errors"] for m in computed),
                   socket_errors={k: sum(m["socket_errors"][k] for m in computed) for k in SOCKETS},
                   total_requests=sum(m["requests"] for m in computed), image_id=build["image_id"],
                   binary_sha256=build["proof"]["binary_sha256"], source_sha256=candidate["source_sha256"],
                   title=candidate["title"], app_goose_sha256=hashes.get("app.goose"))
        result["rows"][case] = row
        sr = [r for r in summary.get("rows", []) if r.get("case_id") == case]
        if summary:
            require(len(sr) == 1 and sr[0].get("status") == "measured", label + ": summary row absent/not measured")
            if sr:
                require(all(close(sr[0].get(k), row[k]) for k in ("rps", "successful_rps", "p50_ms", "p95_ms", "p99_ms", "rss_mib", "cpu_percent", "rps_min", "rps_max")),
                        label + ": summary medians/ranges differ from independent raw recomputation")
                require(sr[0].get("http_errors") == row["http_errors"] and sr[0].get("socket_errors") == row["socket_errors"],
                        label + ": summary errors differ")
                require(all(sr[0].get(k) == row[k] for k in ("image_id", "binary_sha256", "source_sha256")),
                        label + ": summary provenance differs")
                trials = sr[0].get("trials", [])
                require(len(trials) == expected_trials and sorted(v.get("trial") for v in trials) == list(range(1, expected_trials + 1)),
                        label + ": summary does not retain every raw trial")
                for trial in trials:
                    own = next((v for v in result["attempts"] if v["case_id"] == case and v["trial"] == trial.get("trial")), None)
                    if own is None:
                        require(False, label + ": summary contains unknown raw trial")
                        continue
                    for key, value in own["raw"].items():
                        got = trial.get("computed", {}).get(key)
                        require(got == value if isinstance(value, dict) else close(got, value),
                                label + f": summary trial{trial['trial']} raw metric differs: " + key)
                    if name == "confirmation":
                        require(trial.get("included_in_median") is own["selected"],
                                label + ": summary trial inclusion differs from paired policy")
                if name == "confirmation":
                    all_case = [v for v in result["attempts"] if v["case_id"] == case]
                    require(sr[0].get("attempted_http_errors") == sum(v["raw"]["http_errors"] for v in all_case)
                            and sr[0].get("attempted_socket_errors") == {k: sum(v["raw"]["socket_errors"][k] for v in all_case) for k in SOCKETS},
                            label + ": summary does not retain all-attempt error totals")
        if report.is_file():
            matches = [line for line in report.read_text().splitlines() if line.startswith("| " + candidate["title"] + " | measured |")]
            require(len(matches) == 1, label + ": RESULT median row absent/duplicate")
            if matches:
                cells = [x.strip() for x in matches[0].strip("|").split("|")]
                require(cells[2] == f"{row['successful_rps']:,.0f}" and cells[3] == f"{row['rps_min']:,.0f}–{row['rps_max']:,.0f}",
                        label + ": RESULT median/range differs")
                require(cells[5] == f"{row['p95_ms']:.3f} / {row['p99_ms']:.3f}"
                        and cells[6] == f"{row['rss_mib']:.2f}" and cells[7] == f"{row['cpu_percent']:.1f}",
                        label + ": RESULT latency/RSS/CPU median differs")
    if summary:
        require(summary.get("complete") is True and summary.get("attempt_count") == len(records)
                and summary.get("verification_attempt_count") == len(verifications), name + ": summary is incomplete/count differs")
        require(len(summary.get("attempts", [])) == len(records)
                and all(v.get("selected") is (v.get("trial") in selected_rounds)
                        and (not v.get("issues") or v.get("trial") not in selected_rounds)
                        for v in summary.get("attempts", [])),
                name + ": summary selection differs from declared paired policy")
        if name == "confirmation":
            require(summary.get("required_trials") == 7 and summary.get("attempted_rounds") == list(range(1, 8))
                    and summary.get("selected_rounds") == selected_rounds and summary.get("excluded_rounds") == [6]
                    and summary.get("attempted_round_count") == 7 and summary.get("selected_round_count") == 6,
                    name + ": summary paired selection metadata differs")
            require(summary.get("total_http_errors") == sum(v["raw"]["http_errors"] for v in result["attempts"])
                    and summary.get("total_socket_errors") == {k: sum(v["raw"]["socket_errors"][k] for v in result["attempts"]) for k in SOCKETS},
                    name + ": summary all-attempt error totals differ")
    if set(result["rows"]) == {"goose", "82"}:
        ratio = result["rows"]["goose"]["successful_rps"] / result["rows"]["82"]["successful_rps"]
        result.update(goose_to_rust_ratio=ratio, goose_median_difference_percent=100 * (ratio - 1))
        for r in summary.get("rows", []):
            if r.get("case_id") == "goose":
                require(close(r.get("relative_to_control"), ratio), name + ": summary ratio differs")
        if report.is_file():
            goose_title = result["rows"]["goose"]["title"]
            line = next((v for v in report.read_text().splitlines() if v.startswith("| " + goose_title + " | measured |")), "")
            cells = [v.strip() for v in line.strip("|").split("|")]
            require(len(cells) > 4 and cells[4] == f"{ratio:.3f}×", name + ": RESULT ratio differs")
        result["paired_ratios"] = [next(v["raw"]["successful_rps"] for v in result["attempts"] if v["case_id"] == "goose" and v["trial"] == t)
                                  / next(v["raw"]["successful_rps"] for v in result["attempts"] if v["case_id"] == "82" and v["trial"] == t)
                                  for t in range(1, expected_trials + 1)]
        result["selected_paired_ratios"] = [result["paired_ratios"][t-1] for t in selected_rounds]
        result["all_attempt_errors"] = {"http": sum(v["raw"]["http_errors"] for v in result["attempts"]),
                                        "socket": {k: sum(v["raw"]["socket_errors"][k] for v in result["attempts"]) for k in SOCKETS}}
    result["shared_hashes"] = shared
    return result


def main():
    initial = audit_batch(ROOT, 3, [1, 2, 3])
    confirmation = audit_batch(ROOT / "confirmation", 7, [1, 2, 3, 4, 5, 7])
    cross = {}
    if initial.get("rows") and confirmation.get("rows"):
        for case in ("82", "goose"):
            if case not in initial["rows"] or case not in confirmation["rows"]:
                continue
            a, b = initial["rows"][case], confirmation["rows"][case]
            if case == "82":
                cross["rust_unchanged"] = all(a[k] == b[k] for k in ("image_id", "binary_sha256", "source_sha256"))
                require(cross["rust_unchanged"], "cross-batch: Rust source/image/binary changed")
            else:
                cross["same_goose_application"] = a["app_goose_sha256"] == b["app_goose_sha256"]
                cross["app_goose_sha256"] = a["app_goose_sha256"]
                require(cross["same_goose_application"], "cross-batch: app.goose changed")
        cross["same_shared_fixture_harness"] = initial.get("shared_hashes") == confirmation.get("shared_hashes")
        require(cross["same_shared_fixture_harness"], "cross-batch: shared fixture/harness identities changed")
        for rel in ("serve.py", "semantic.py", "mixed.lua", "test/test.sh", "test/run.sh", "schema.sql", "seccomp-io-uring.json"):
            a, b = ROOT / rel, ROOT / "confirmation" / rel
            require(a.is_file() and b.is_file() and digest(a) == digest(b), "cross-batch: harness file changed: " + rel)
        original_controller = (ROOT / "run.py").read_text()
        controller = (ROOT / "confirmation/run.py").read_text()
        old_tree, new_tree = ast.parse(original_controller), ast.parse(controller)
        found_arg, found_loop = 0, 0
        class NormalizeController(ast.NodeTransformer):
            def visit_Expr(self, node):
                nonlocal found_arg
                call = node.value
                if isinstance(call, ast.Call) and isinstance(call.func, ast.Attribute) and call.func.attr == "add_argument" \
                        and call.args and isinstance(call.args[0], ast.Constant) and call.args[0].value == "--start-trial":
                    found_arg += 1
                    options = {v.arg: v.value for v in call.keywords}
                    require(isinstance(options.get("type"), ast.Name) and options["type"].id == "int"
                            and isinstance(options.get("default"), ast.Constant) and options["default"].value == 1,
                            "controller: --start-trial must be integer with default1")
                    return None
                return self.generic_visit(node)
            def visit_For(self, node):
                nonlocal found_loop
                if isinstance(node.target, ast.Name) and node.target.id == "trial" and isinstance(node.iter, ast.Call) \
                        and isinstance(node.iter.func, ast.Name) and node.iter.func.id == "range":
                    first = node.iter.args[0]
                    allowed_starts = [ast.parse(text, mode="eval").body for text in
                                      ("args.start_trial if args.mode == 'bench' else 1",
                                       "1 if args.mode == 'verify' else args.start_trial")]
                    require(any(ast.dump(first) == ast.dump(v) for v in allowed_starts),
                            "controller: trial loop start differs from approved mode-dependent start argument")
                    found_loop += 1
                    node.iter.args[0] = ast.Constant(value=1)
                return self.generic_visit(node)
        normalized = NormalizeController().visit(new_tree)
        cross["controller_delta_only_start_trial_argument_and_loop_start"] = (
            found_arg == 1 and found_loop == 1 and ast.dump(old_tree) == ast.dump(normalized))
        require(cross["controller_delta_only_start_trial_argument_and_loop_start"],
                "cross-batch: controller changed beyond --start-trial argument and loop start")
        cross["initial_controller_sha256"] = hashlib.sha256(original_controller.encode()).hexdigest()
        cross["confirmation_controller_sha256"] = hashlib.sha256(controller.encode()).hexdigest()
        archived_controller = ROOT / "confirmation/archives/original-six-rounds/run.py"
        require(archived_controller.is_file() and archived_controller.read_text() == original_controller,
                "controller: archived original is not byte-identical to initial controller")
        archived_attempts = load(ROOT / "confirmation/archives/original-six-rounds/measurements.json", [])
        final_attempts = load(ROOT / "confirmation/measurements.json", [])
        cross["original_twelve_attempts_preserved_exactly"] = len(archived_attempts) == 12 and final_attempts[:12] == archived_attempts
        require(cross["original_twelve_attempts_preserved_exactly"], "original twelve confirmation attempts were changed/lost")
        decision = load(ROOT / "confirmation/paired-retry-decision.json", {})
        decision_time = dt.datetime.fromisoformat(decision["recorded_at"].replace("Z", "+00:00"))
        round7_times = [dt.datetime.fromisoformat(v["recorded_at"].replace("Z", "+00:00"))
                        for v in final_attempts if v.get("trial") == 7]
        cross["retry_policy_recorded_before_round7"] = len(round7_times) == 2 and all(decision_time < v for v in round7_times)
        require(cross["retry_policy_recorded_before_round7"] and decision.get("no_further_retries") is True
                and decision.get("all_attempt_errors_reported") is True,
                "round7 policy was not recorded before both attempts or permits further retries")
        cross["retry_policy_sha256"] = digest(ROOT / "confirmation/paired-retry-decision.json")
        edge_a, edge_b = (ROOT / "edge_checks.py").read_text(), (ROOT / "confirmation/edge_checks.py").read_text()
        normalize = lambda text: re.sub(r"^IMAGE_ID = .*$", "IMAGE_ID = <batch-specific image>", text, flags=re.M)
        cross["same_supplemental_checks_except_image_parameter"] = normalize(edge_a) == normalize(edge_b)
        require(cross["same_supplemental_checks_except_image_parameter"], "cross-batch: supplemental checks changed beyond image parameter")
        env_a, env_b = load(ROOT / "environment-bench.json", {}), load(ROOT / "confirmation/environment-bench.json", {})
        environment_keys = ("load_image_id", "server_cpus", "server_cpu_quota", "server_memory", "server_memory_swap",
                            "load_cpus", "load_cpu_quota", "load_memory", "nofile", "server_seccomp", "cpu_accounting", "host_cpu", "host_uname")
        cross["same_recorded_environment"] = all(env_a.get(k) == env_b.get(k) for k in environment_keys)
        require(cross["same_recorded_environment"], "cross-batch: recorded environment differs")
        frozen = load(ROOT / "confirmation/archives/prgoose-sha256.json", {})
        mismatches = [rel for rel, wanted in frozen.items() if not (REPO / "submissions/goose-native-tbsvttr" / rel).is_file()
                      or digest(REPO / "submissions/goose-native-tbsvttr" / rel) != wanted]
        cross["current_submission_matches_confirmation_inventory"] = not mismatches
        cross["submission_mismatches"] = mismatches
        require(not mismatches, "current Goose submission differs from frozen confirmation: " + ", ".join(mismatches))
    rejection = ROOT / "toolchain/confirmation-build-rejected-profile-guard.log"
    rejected_manifest = load(ROOT / "confirmation/archives/rejected-pgo-build/manifest.json", [])
    build_only = {"attempt_count": 1, "classification": "build only; never a measured trial",
                  "log": str(rejection.relative_to(ROOT)), "log_sha256": digest(rejection) if rejection.exists() else None,
                  "failed_guard": "SQLite PGO training produced no profile.",
                  "source_sha256": next((v.get("source_sha256") for v in rejected_manifest if v.get("case_id") == "goose"), None)}
    require(rejection.is_file() and "SQLite PGO training produced no profile." in rejection.read_text()
            and "exit code: 1" in rejection.read_text(), "rejected PGO build-only guard failure evidence missing")
    require(not any(v.get("source_sha256") == build_only["source_sha256"] for b in (initial, confirmation) for v in b["attempts"]),
            "rejected build-only source appears in measured attempts")
    status = "fail" if ISSUES else "pending" if PENDING else "pass"
    result = dict(status=status, audited_at=dt.datetime.now(dt.timezone.utc).isoformat(),
                  initial_archived_reference=initial, final_confirmation=confirmation,
                  cross_batch=cross, rejected_build_only_attempt=build_only,
                  measured_attempt_count=initial["measurement_attempt_count"] + confirmation["measurement_attempt_count"],
                  verification_attempt_count=initial["verification_attempt_count"] + confirmation["verification_attempt_count"],
                  measured_error_totals={"http": sum(v["raw"]["http_errors"] for b in (initial, confirmation) for v in b["attempts"]),
                                         "socket": {k: sum(v["raw"]["socket_errors"][k] for b in (initial, confirmation) for v in b["attempts"]) for k in SOCKETS}},
                  issues=ISSUES, pending=sorted(set(PENDING)),
                  limitations=["Offline audit checks retained evidence and hashes; it does not rerun images or authenticate their provenance independently.",
                               "Local ARM64 Docker Desktop mixed-throughput experiment, not the official k6 capacity score or an isolated language comparison.",
                               "PGO and read-once change together in confirmation; their individual effects cannot be separated.",
                               "Confirmation pair6 retains58Rustsockettimeouts and is wholly excluded from clean medians under the predeclared one-pair retry policy; no further retries are permitted.",
                               "Per-run percentiles are summarized by their median; RSS is sampled process memory, not peak container memory."])
    (ROOT / "audit-experiment.json").write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps({k: result[k] for k in ("status", "measured_attempt_count", "verification_attempt_count", "issues", "pending")}, indent=2))
    return 0 if status == "pass" else 2 if status == "pending" else 1


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (KeyError, TypeError, ValueError, AttributeError, ZeroDivisionError) as error:
        issue = f"Malformed/incomplete evidence: {type(error).__name__}: {error}"
        (ROOT / "audit-experiment.json").write_text(json.dumps(dict(status="fail", issues=ISSUES + [issue], pending=PENDING), indent=2) + "\n")
        print(issue, file=sys.stderr)
        sys.exit(1)
