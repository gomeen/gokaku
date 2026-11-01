#!/usr/bin/env python3
"""Run isolated Xiaohe workers; measure core generation separately from IPC."""
import argparse
import gzip
import hashlib
import json
import math
import os
from pathlib import Path
import platform
import selectors
import subprocess
import sys
import time

HERE = Path(__file__).resolve().parent


def dump(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, ensure_ascii=False, indent=2) + "\n")


def sha(path):
    h = hashlib.sha256()
    with Path(path).open("rb") as f:
        for block in iter(lambda: f.read(1024 * 1024), b""):
            h.update(block)
    return h.hexdigest()


def command_output(command):
    p = subprocess.run(command, capture_output=True, text=True, timeout=15)
    return {"command": command, "returncode": p.returncode, "stdout": p.stdout.strip(), "stderr": p.stderr.strip()}


def host_info():
    return {"timestamp": time.strftime("%Y-%m-%dT%H:%M:%S%z"), "platform": platform.platform(),
            "python": sys.version, "loadavg": list(os.getloadavg()),
            "hardware": command_output(["sysctl", "-n", "hw.model", "hw.physicalcpu", "hw.logicalcpu", "hw.memsize"]),
            "system": command_output(["sw_vers"]),
            "power": command_output(["pmset", "-g", "batt"]),
            "thermal": command_output(["pmset", "-g", "therm"])}


class Worker:
    def __init__(self, config, log_dir, offline=False):
        self.config = config
        self.command = list(config["command"])
        if offline:
            self.command = ["/usr/bin/sandbox-exec", "-p", "(version 1)(allow default)(deny network*)"] + self.command
        self.stderr = (log_dir / (config["id"] + ".stderr.log")).open("wb")
        self.buffer = b""
        self.sel = selectors.DefaultSelector()
        started = time.perf_counter_ns()
        self.process = subprocess.Popen(self.command, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                        stderr=self.stderr, bufsize=0)
        self.sel.register(self.process.stdout, selectors.EVENT_READ)
        try:
            self.ready = json.loads(self.readline(180))
            self.parent_ready_ms = (time.perf_counter_ns() - started) / 1e6
            if not self.ready.get("ready"):
                raise ValueError("Worker did not emit ready: " + repr(self.ready))
        except BaseException:
            self.process.kill()
            self.process.wait()
            self.sel.close()
            self.stderr.close()
            raise

    def readline(self, timeout):
        deadline = time.monotonic() + timeout
        while b"\n" not in self.buffer:
            remaining = deadline - time.monotonic()
            if remaining <= 0 or not self.sel.select(remaining):
                raise TimeoutError("Worker response timed out: " + self.config["id"])
            data = os.read(self.process.stdout.fileno(), 65536)
            if not data:
                raise EOFError("Worker exited: " + self.config["id"] + ", code=" + str(self.process.poll()))
            self.buffer += data
            if len(self.buffer) > 8 * 1024 * 1024:
                raise ValueError("Oversized worker response")
        line, self.buffer = self.buffer.split(b"\n", 1)
        return line

    def request(self, request, timeout=30, validate=True):
        data = (json.dumps(request, separators=(",", ":")) + "\n").encode()
        start = time.perf_counter_ns()
        self.process.stdin.write(data)
        raw = self.readline(timeout)
        rtt = time.perf_counter_ns() - start
        response = json.loads(raw)
        if not response.get("ok"):
            raise ValueError(self.config["id"] + " rejected " + repr(request) + ": " + repr(response))
        if validate:
            for field in ("preedit", "commit"):
                if not isinstance(response.get(field), str):
                    raise ValueError("Missing/non-string " + field)
            if response.get("raw_input") is not None and not isinstance(response["raw_input"], str):
                raise ValueError("raw_input must be text or null")
            if not isinstance(response.get("composing"), bool):
                raise ValueError("Missing composition state")
            candidates = response.get("candidates")
            if not isinstance(candidates, list) or len(candidates) > 10 or not all(isinstance(c, str) for c in candidates):
                raise ValueError("Invalid candidate collection: " + repr(candidates))
            for field in ("process_ns", "collect_ns", "total_ns"):
                if not isinstance(response.get(field), int) or response[field] < 0:
                    raise ValueError("Invalid timing " + field)
            if response["total_ns"] < response["process_ns"] + response["collect_ns"]:
                raise ValueError("total_ns omits one or more stages")
        return response, rtt

    def type(self, keys, fresh=False):
        self.request({"op": "reset", "fresh": fresh})
        steps = []
        for key in keys:
            response, rtt = self.request({"op": "key", "key": ord(key)})
            steps.append({"key": key, "response": response, "parent_rtt_ns": rtt})
        return steps

    def resources(self):
        p = subprocess.run(["ps", "-o", "rss=,time=,pcpu=", "-p", str(self.process.pid)], capture_output=True, text=True, timeout=5)
        fields = p.stdout.split()
        return {"pid": self.process.pid, "rss_bytes": int(fields[0]) * 1024 if fields else None,
                "cpu_time": fields[1] if len(fields) > 1 else None,
                "pcpu": float(fields[2]) if len(fields) > 2 else None}

    def close(self):
        error = None
        try:
            if self.process.poll() is None:
                self.request({"op": "quit"}, timeout=5, validate=False)
                self.process.stdin.close()
                self.process.wait(timeout=10)
            if self.process.returncode:
                error = "Worker exit code " + str(self.process.returncode)
        except Exception as e:
            error = str(e)
            if self.process.poll() is None:
                self.process.kill()
            self.process.wait()
        finally:
            self.sel.close()
            self.process.stdout.close()
            if not self.process.stdin.closed:
                self.process.stdin.close()
            self.stderr.close()
        if error:
            raise RuntimeError(self.config["id"] + ": " + error)


def summary(values):
    values = sorted(values)
    if not values:
        return {"n": 0}
    def q(p):
        rank = (len(values) - 1) * p
        lower, upper = math.floor(rank), math.ceil(rank)
        return (values[lower] + (values[upper] - values[lower]) * (rank - lower)) / 1e6
    return {"n": len(values), "p50_ms": q(.5), "p95_ms": q(.95), "p99_ms": q(.99),
            "max_ms": values[-1] / 1e6, "mean_ms": sum(values) / len(values) / 1e6}


def load_configs(paths, ids):
    configs = []
    excluded = []
    manifests = []
    for path in paths:
        manifest = json.loads(path.read_text())
        manifests.append({"path": str(path), "sha256": sha(path), "content": manifest})
        for config in manifest.get("configs", [manifest]):
            if not config.get("command") or config.get("available") is False:
                excluded.append(config)
                continue
            if ids and config.get("id") not in ids:
                continue
            if not config.get("id") or any(c["id"] == config["id"] for c in configs):
                raise ValueError("Missing or duplicate config id")
            if not config["id"].replace("-", "").replace("_", "").isalnum():
                raise ValueError("Unsafe config id")
            configs.append(config)
    if not configs:
        raise ValueError("No runnable configurations")
    return configs, excluded, manifests


def smoke(worker):
    records = []
    empty, _ = worker.request({"op": "reset"})
    if empty["composing"] or empty["commit"]:
        raise ValueError("reset leaves composition/commit")
    for keys in ("nihc", "kdhv", "woxlxtykyu"):
        steps = worker.type(keys)
        final = steps[-1]["response"]
        if not final["composing"] or not final["candidates"] or any(s["response"]["commit"] for s in steps):
            raise ValueError("Chinese composition failed: " + keys + " " + repr(final))
        peek, _ = worker.request({"op": "peek"})
        if peek["candidates"] != final["candidates"]:
            raise ValueError("Candidates change without input; asynchronous configuration needs separate handling")
        selected, _ = worker.request({"op": "select", "index": 0})
        records.append({"input": keys, "steps": steps, "peek": peek, "select_first": selected})
    worker.type("nihc")
    backspace, _ = worker.request({"op": "key", "key": 8})
    if backspace["commit"] or not backspace["composing"]:
        raise ValueError("Backspace unexpectedly commits/clears all")
    if backspace["raw_input"] is not None and backspace["raw_input"] != "nih":
        raise ValueError("Backspace raw input mismatch: " + repr(backspace))
    retyped, _ = worker.request({"op": "key", "key": ord("c")})
    space, _ = worker.request({"op": "key", "key": 32})
    if space["composing"] or space["commit"] != retyped["candidates"][0]:
        raise ValueError("Space did not commit the displayed complete greeting")
    worker.type("nihc")
    cancelled, _ = worker.request({"op": "key", "key": 27})
    if cancelled["commit"] or cancelled["composing"]:
        raise ValueError("Escape commits or retains composition")
    alternate_steps = worker.type("hvyi")
    alternate_candidates = alternate_steps[-1]["response"]["candidates"]
    alternate = None
    if len(alternate_candidates) > 1:
        state, _ = worker.request({"op": "select", "index": 1})
        if not state["composing"] and state["commit"] != alternate_candidates[1]:
            raise ValueError("Explicit selection committed a different candidate")
        alternate = {"displayed": alternate_candidates[1], "state": state}
    full_target = "我想学英语"
    partial_steps = worker.type("woxlxtykyu")
    partial_candidates = partial_steps[-1]["response"]["candidates"]
    partial_index = next((i for i, candidate in enumerate(partial_candidates)
                          if candidate and candidate != full_target and full_target.startswith(candidate)), None)
    partial = {"available_in_first_ten": partial_index is not None}
    if partial_index is not None:
        state, _ = worker.request({"op": "select", "index": partial_index})
        trajectory = [state]
        committed = state["commit"]
        for _ in range(8):
            if not state["composing"] or not state["candidates"]:
                break
            state, _ = worker.request({"op": "select", "index": 0})
            trajectory.append(state)
            committed += state["commit"]
        partial.update({"displayed_prefix": partial_candidates[partial_index], "trajectory": trajectory,
                        "committed": committed, "complete_target": not state["composing"] and committed == full_target})
    return {"cases": records, "backspace": backspace, "retyped": retyped, "space": space,
            "cancelled": cancelled, "explicit_second": alternate, "partial_selection": partial}


def quality(worker, cases):
    result = []
    for case in cases:
        steps = worker.type(case["keys"], fresh=True)
        final = steps[-1]["response"]
        candidates = final["candidates"]
        match = next((i for i, text in enumerate(candidates) if text in case["targets"]), None)
        selected = None
        if match is not None:
            selected, _ = worker.request({"op": "select", "index": match})
        committed_while_typing = "".join(s["response"]["commit"] for s in steps)
        complete = bool(selected and not selected["composing"] and
                        committed_while_typing + selected["commit"] in case["targets"])
        result.append({**case, "top1": bool(candidates and candidates[0] in case["targets"]),
                       "top10": match is not None, "target_index": match, "single_selection_complete": complete,
                       "steps": steps, "final": final, "selected": selected,
                       "committed_while_typing": committed_while_typing})
    by_stratum = {}
    for stratum in sorted({c["stratum"] for c in cases}):
        rows = [r for r in result if r["stratum"] == stratum]
        by_stratum[stratum] = {"n": len(rows), **{field: sum(r[field] for r in rows) for field in ("top1", "top10", "single_selection_complete")}}
    return {"n": len(result), **{field: sum(r[field] for r in result) for field in ("top1", "top10", "single_selection_complete")},
            "by_stratum": by_stratum, "cases": result}


def measure(workers, cases, rounds, output):
    values = {w.config["id"]: {"core": [], "process": [], "collect": [], "rtt": [], "final": [], "strata": {}} for w in workers}
    rounds_log = []
    for worker in workers:
        for case in cases:
            worker.type(case["keys"])
    with gzip.open(output / "events.jsonl.gz", "wt", encoding="utf-8") as event_file:
        for round_index in range(rounds):
            order = workers[round_index % len(workers):] + workers[:round_index % len(workers)]
            round_record = {"round": round_index, "order": [w.config["id"] for w in order],
                            "loadavg_before": list(os.getloadavg()), "configs": {}}
            for worker in order:
                config_id = worker.config["id"]
                before = worker.resources()
                started = time.perf_counter_ns()
                samples = []
                for case in cases:
                    worker.request({"op": "reset"})
                    for step, key in enumerate(case["keys"]):
                        response, rtt = worker.request({"op": "key", "key": ord(key)})
                        if response["commit"]:
                            raise ValueError("Unexpected commit during timing: " + config_id + "/" + case["id"])
                        event = {"config": config_id, "round": round_index, "case": case["id"],
                                 "stratum": case["stratum"], "step": step, "key": key,
                                 "parent_rtt_ns": rtt, "response": response}
                        event_file.write(json.dumps(event, ensure_ascii=False, separators=(",", ":")) + "\n")
                        store = values[config_id]
                        for name, field in (("core", "total_ns"), ("process", "process_ns"), ("collect", "collect_ns")):
                            store[name].append(response[field])
                        store["rtt"].append(rtt)
                        store["strata"].setdefault(case["stratum"], []).append(response["total_ns"])
                        if step == len(case["keys"]) - 1:
                            store["final"].append(response["total_ns"])
                        samples.append(response["total_ns"])
                round_record["configs"][config_id] = {"wall_ms": (time.perf_counter_ns() - started) / 1e6,
                                                        "core": summary(samples), "resources_before": before,
                                                        "resources_after": worker.resources()}
            round_record["loadavg_after"] = list(os.getloadavg())
            rounds_log.append(round_record)
            event_file.flush()
            dump(output / "rounds.json", rounds_log)
            print("round " + str(round_index + 1) + "/" + str(rounds) + " complete", flush=True)
    result = {}
    for config_id, store in values.items():
        result[config_id] = {key: summary(store[key]) for key in ("core", "process", "collect", "rtt", "final")}
        result[config_id]["strata"] = {key: summary(samples) for key, samples in store["strata"].items()}
        result[config_id]["round_p50_range_ms"] = [min(r["configs"][config_id]["core"]["p50_ms"] for r in rounds_log),
                                                    max(r["configs"][config_id]["core"]["p50_ms"] for r in rounds_log)]
        result[config_id]["sampled_peak_rss_bytes"] = max(r["configs"][config_id]["resources_after"]["rss_bytes"] for r in rounds_log)
    dump(output / "measurement-summary.json", {"rounds": rounds, "keys_per_round": sum(len(c["keys"]) for c in cases),
                                                "configs": result, "scope": "Hot serial key-to-ten-candidates in core; no UI/host/translation"})


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--manifest", type=Path, action="append", required=True)
    parser.add_argument("--ids", nargs="*")
    parser.add_argument("--cases", type=Path, default=HERE / "input-engine-cases.json")
    parser.add_argument("--phases", nargs="+", choices=("smoke", "quality", "measure", "offline"), default=["smoke", "quality", "measure", "offline"])
    parser.add_argument("--rounds", type=int, default=33)
    parser.add_argument("--output-dir", type=Path, required=True)
    args = parser.parse_args()
    if args.rounds < 5 and "measure" in args.phases:
        parser.error("Formal measurements require at least five rounds")
    configs, excluded, manifests = load_configs(args.manifest, args.ids)
    cases = json.loads(args.cases.read_text())["cases"]
    args.output_dir.mkdir(parents=True, exist_ok=True)
    for phase in args.phases:
        output = args.output_dir / phase
        if output.exists():
            raise FileExistsError("Refusing to overwrite phase results: " + str(output))
        output.mkdir()
        dump(output / "environment.json", host_info())
        dump(output / "inputs.json", {"cases_path": str(args.cases), "cases_sha256": sha(args.cases), "cases": cases,
                                       "manifests": manifests, "excluded": excluded, "configs": configs,
                                       "runner_sha256": sha(__file__)})
        if phase == "offline":
            probe = command_output(["/usr/bin/sandbox-exec", "-p", "(version 1)(allow default)(deny network*)",
                                    sys.executable, "-c", "import socket; socket.create_connection(('1.1.1.1',443),timeout=2)"])
            dump(output / "network-control.json", probe)
            if probe["returncode"] == 0 or "Operation not permitted" not in probe["stderr"]:
                raise RuntimeError("Network-denial control not established")
        workers = []
        status = {"complete": False, "phase": phase, "started": time.strftime("%Y-%m-%dT%H:%M:%S%z")}
        try:
            for config in configs:
                workers.append(Worker(config, output, offline=phase == "offline"))
            dump(output / "startup.json", {w.config["id"]: {"ready": w.ready, "parent_ready_ms": w.parent_ready_ms,
                                                             "resources": w.resources(), "command": w.command} for w in workers})
            if phase in ("smoke", "offline"):
                for worker in workers:
                    dump(output / (worker.config["id"] + ".json"), smoke(worker))
            elif phase == "quality":
                for worker in workers:
                    dump(output / (worker.config["id"] + ".json"), quality(worker, cases))
            elif phase == "measure":
                measure(workers, cases, args.rounds, output)
            status["complete"] = True
        except BaseException as e:
            status["error"] = type(e).__name__ + ": " + str(e)
            raise
        finally:
            close_errors = []
            for worker in workers:
                try:
                    worker.close()
                except Exception as e:
                    close_errors.append(str(e))
            if close_errors:
                status["close_errors"] = close_errors
                status["complete"] = False
            status["finished"] = time.strftime("%Y-%m-%dT%H:%M:%S%z")
            status["loadavg_end"] = list(os.getloadavg())
            dump(output / "status.json", status)
        if not status["complete"]:
            raise RuntimeError("Incomplete phase: " + repr(status))
        print(phase + " complete", flush=True)


if __name__ == "__main__":
    main()
