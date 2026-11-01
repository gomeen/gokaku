"""Run independent translation workers; preserve every output and failure."""
import atexit
import argparse
import datetime
import hashlib
import json
import os
from pathlib import Path
import queue
import random
import statistics
import subprocess
import sys
import threading
import time

BASE = Path(__file__).resolve().parent
CASES_PATH = BASE / "translation-cases.json"
PERFORMANCE_IDS = ["en-word", "en-phrase", "en-sentence", "en-negation", "en-long", "zh-word", "zh-phrase", "zh-sentence", "zh-negation", "zh-long"]
TUNING_IDS = ["en-word", "en-sentence", "zh-word", "zh-sentence"]
CONFIGS = {}
for family in ["opus", "m2m100"]:
    for precision in ["float32", "int8"]:
        for threads in [1, 2, 4, 8]:
            name = f"{family}-ct2-{precision}-t{threads}"
            CONFIGS[name] = {"id": name, "model": family, "backend": "ct2", "device": "cpu", "precision": precision, "threads": threads, "beam": 1}
    for threads in [1, 2, 4, 8]:
        name = f"{family}-torch-cpu-t{threads}"
        CONFIGS[name] = {"id": name, "model": family, "backend": "torch", "device": "cpu", "precision": "float32", "threads": threads, "beam": 1}
    for precision in ["float32", "float16"]:
        name = f"{family}-torch-mps-{precision}"
        CONFIGS[name] = {"id": name, "model": family, "backend": "torch", "device": "mps", "precision": precision, "threads": 1, "beam": 1}
        fallback_name = name + "-fallback"
        CONFIGS[fallback_name] = {**CONFIGS[name], "id": fallback_name, "mps_cpu_fallback": True}


class Worker:
    def __init__(self, config, root, log_path):
        self.log = log_path.open("w")
        self.process = subprocess.Popen([config.get("python_executable", sys.executable), "-u", str(BASE / "translation-worker.py"), "--config", json.dumps(config), "--root", str(root)], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=self.log, text=True, bufsize=1, start_new_session=True)
        atexit.register(self.close)
        self.messages = queue.Queue()
        self.reader = threading.Thread(target=self.read_output, daemon=True)
        self.reader.start()
        start = time.perf_counter()
        try:
            self.ready = self.read()
            self.ready["parent_ready_ms"] = (time.perf_counter() - start) * 1000
            if self.ready.get("event") != "ready":
                raise RuntimeError(json.dumps(self.ready))
        except Exception:
            self.close()
            raise

    def read_output(self):
        for line in self.process.stdout:
            self.messages.put(line)
        self.messages.put(None)

    def read(self):
        try:
            line = self.messages.get(timeout=180)
        except queue.Empty:
            raise TimeoutError("Worker produced no protocol message within 180 seconds")
        if line is None:
            self.process.wait(timeout=10)
            raise RuntimeError(f"Worker exited with status {self.process.returncode}")
        return json.loads(line)

    def request(self, cases, phase):
        self.process.stdin.write(json.dumps({"cases": cases, "phase": phase}, ensure_ascii=False) + "\n")
        self.process.stdin.flush()
        rows = []
        while True:
            row = self.read()
            if row["event"] == "request_done":
                return rows
            if row["event"] != "result":
                raise RuntimeError(f"Unexpected worker event: {row}")
            rows.append(row)

    def stop(self):
        self.process.stdin.write('{"event":"stop"}\n')
        self.process.stdin.flush()
        result = self.read()
        self.process.wait(timeout=20)
        return result

    def close(self):
        if self.process.poll() is None:
            self.process.kill()
            self.process.wait(timeout=20)
        self.log.close()


def system_state():
    return {"uptime": subprocess.check_output(["uptime"], text=True).strip(), "load_average": os.getloadavg(), "cpu_processes": subprocess.check_output("ps -A -o pid,pcpu,comm | sort -k2 -rn | head -10", shell=True, text=True).splitlines()}


def run_pass(config, root, cases, warmups, phase, round_index, directory, workers=None):
    result = {"config": config, "round": round_index, "phase": phase, "started_at": datetime.datetime.now(datetime.timezone.utc).isoformat(), "system_before": system_state(), "rows": [], "warmup_rows": []}
    worker = None
    log_path = directory / f"{phase}-{round_index}-{config['id']}.stderr.log"
    result["stderr_log"] = os.path.relpath(log_path, BASE.parent)
    try:
        reused = workers is not None and config["id"] in workers
        worker = workers[config["id"]] if reused else Worker(config, root, log_path)
        if workers is not None:
            workers[config["id"]] = worker
        result["ready"] = worker.ready
        result["stderr_log"] = os.path.relpath(worker.log.name, BASE.parent)
        result["ready_reused"] = reused
        result["warmup_rows"] = worker.request(warmups, "warmup")
        if any(not row["generated"] for row in result["warmup_rows"]):
            result["status"] = "warmup_failed"
        else:
            profiler = None
            if phase == "profile":
                profile_path = directory / (config["id"] + ".sample.txt")
                profiler = subprocess.Popen(["sample", str(worker.process.pid), "2", "1", "-file", str(profile_path)], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                result["profile"] = os.path.relpath(profile_path, BASE.parent)
                cases = cases * 12
            result["rows"] = worker.request(cases, phase)
            if profiler is not None:
                result["profiler_returncode"] = profiler.wait(timeout=20)
            result["status"] = "completed"
        if workers is None:
            result["shutdown"] = worker.stop()
    except Exception as error:
        result["status"] = "failed"
        result["error"] = repr(error)
        if workers is not None:
            workers.pop(config["id"], None)
        if worker is not None:
            worker.close()
    finally:
        if worker is not None and workers is None:
            worker.close()
    result["system_after"] = system_state()
    result["errors"] = sum(not row.get("generated", False) for row in result["rows"] + result["warmup_rows"])
    result["worker_failures"] = int(result["status"] == "failed")
    return result


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", type=Path, default=Path("/tmp/gogaku-benchmark/models"))
    parser.add_argument("--configs", nargs="+", choices=list(CONFIGS), required=True)
    parser.add_argument("--ct2-python", type=Path, default=Path("/tmp/gogaku-benchmark/venv-ct2/bin/python"))
    parser.add_argument("--phase", choices=["smoke", "quality", "tune", "measure", "profile"], required=True)
    parser.add_argument("--rounds", type=int, default=1)
    parser.add_argument("--beam", type=int, choices=[1, 4], default=1)
    parser.add_argument("--cases", nargs="+")
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--keep-workers", action="store_true")
    parser.add_argument("--resume", action="store_true")
    args = parser.parse_args()
    args.output = args.output.resolve()
    if args.phase == "measure" and args.rounds < 5:
        parser.error("Comparative measurement requires at least five rounds")
    all_cases = json.loads(CASES_PATH.read_text())
    by_id = {case["id"]: case for case in all_cases}
    selected_ids = args.cases or (list(by_id) if args.phase == "quality" else TUNING_IDS if args.phase == "tune" else PERFORMANCE_IDS)
    cases = [by_id[name] for name in selected_ids]
    warmups = [by_id["en-word"], by_id["zh-word"]]
    args.output.parent.mkdir(parents=True, exist_ok=True)
    if args.output.exists() and not args.resume:
        parser.error("Output exists; use a new path or --resume")
    metadata = {"phase": args.phase, "configs": args.configs, "rounds": args.rounds, "beam": args.beam, "keep_workers": args.keep_workers, "case_ids": selected_ids, "dataset_sha256": hashlib.sha256(CASES_PATH.read_bytes()).hexdigest(), "root": str(args.root.resolve())}
    if args.output.exists():
        report = json.loads(args.output.read_text())
        if report["parameters"] != metadata:
            parser.error("Cannot resume with changed parameters or dataset")
    else:
        report = {"parameters": metadata, "passes": []}
    done = {(entry["round"], entry["config"]["id"]) for entry in report["passes"]}
    workers = {} if args.keep_workers else None
    for round_index in range(args.rounds):
        names = list(args.configs)
        random.Random(4107 + round_index).shuffle(names)
        for name in names:
            if (round_index, name) in done:
                continue
            config = {**CONFIGS[name], "beam": args.beam, "python_executable": str(args.ct2_python) if CONFIGS[name]["backend"] == "ct2" else sys.executable}
            order = list(cases)
            random.Random(701 + round_index).shuffle(order)
            print(f"{args.phase} round {round_index + 1}/{args.rounds}: {name}, beam={args.beam}", flush=True)
            result = run_pass(config, args.root, order, warmups, args.phase, round_index, args.output.parent, workers)
            report["passes"].append(result)
            temporary = args.output.with_suffix(".writing")
            temporary.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")
            temporary.replace(args.output)
            times = [row["total_ms"] for row in result["rows"] if row.get("generated")]
            print(json.dumps({"status": result["status"], "generated_rows": len(times), "errors": result["errors"], "error": result.get("error"), "median_ms": statistics.median(times) if times else None}), flush=True)
    if workers is not None:
        for worker in workers.values():
            try:
                worker.stop()
            finally:
                worker.close()
