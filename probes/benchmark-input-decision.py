#!/usr/bin/env python3
"""Bounded paced-core + controlled AppKit test, optionally with real CT2 contention."""
import argparse
import importlib.util
import json
import os
from pathlib import Path
import selectors
import subprocess
import sys
import threading
import time

HERE = Path(__file__).resolve().parent


def module(name, filename):
    spec = importlib.util.spec_from_file_location(name, HERE / filename)
    value = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(value)
    return value


core = module("input_benchmark", "benchmark-input-engines.py")
translation = module("translation_benchmark", "benchmark-translations.py")


class NativeClient:
    def __init__(self, executable, output):
        self.rasterize = False
        self.log = (output / "native.stderr.log").open("wb")
        self.process = subprocess.Popen([str(executable)], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                        stderr=self.log, bufsize=0)
        self.selector = selectors.DefaultSelector()
        self.selector.register(self.process.stdout, selectors.EVENT_READ)
        self.buffer = b""

    def request(self, value):
        self.process.stdin.write((json.dumps(value, ensure_ascii=False) + "\n").encode())
        deadline = time.monotonic() + 30
        while b"\n" not in self.buffer:
            remaining = deadline - time.monotonic()
            if remaining <= 0 or not self.selector.select(remaining):
                raise TimeoutError("Controlled AppKit client timed out")
            data = os.read(self.process.stdout.fileno(), 65536)
            if not data:
                raise EOFError("Controlled AppKit client exited")
            self.buffer += data
        line, self.buffer = self.buffer.split(b"\n", 1)
        response = json.loads(line)
        if not response.get("ok"):
            raise RuntimeError(response)
        return response

    def render(self, response):
        return self.request({"op": "render", "state": response, "rasterize": self.rasterize})

    def close(self):
        try:
            if self.process.poll() is None:
                self.request({"op": "quit"})
                self.process.wait(timeout=10)
            if self.process.returncode:
                raise RuntimeError("Native client exit " + str(self.process.returncode))
        finally:
            if self.process.poll() is None:
                self.process.kill()
                self.process.wait()
            self.selector.close()
            self.process.stdin.close()
            self.process.stdout.close()
            self.log.close()


def contracts(worker, native):
    rows = []
    prefix = "既有文字🙂 "
    for keys, target in [("nihc", "你好"), ("woxlxtykyu", "我想学英语")]:
        native.request({"op": "reset", "text": prefix})
        worker.request({"op": "reset", "fresh": True})
        for key in keys:
            state, _ = worker.request({"op": "key", "key": ord(key)})
            view = native.render(state)
            if state["commit"] or not view["has_marked_text"]:
                raise ValueError("Preedit unexpectedly commits")
        index = state["candidates"].index(target)
        state, _ = worker.request({"op": "select", "index": index})
        view = native.render(state)
        assert state["commit"] == target and not state["composing"]
        assert view["host_text"] == prefix + target and not view["has_marked_text"], view
        rows.append({"operation": "full_commit", "keys": keys, "view": view})
    native.request({"op": "reset", "text": prefix})
    worker.request({"op": "reset", "fresh": True})
    for key in "nihc":
        state, _ = worker.request({"op": "key", "key": ord(key)})
        native.render(state)
    state, _ = worker.request({"op": "key", "key": 8})
    native.render(state)
    assert not state["commit"] and state["composing"]
    state, _ = worker.request({"op": "key", "key": 27})
    view = native.render(state)
    assert view["host_text"] == prefix and not view["has_marked_text"], view
    rows.append({"operation": "backspace_then_cancel", "view": view})
    for mode in ["second", "partial"]:
        native.request({"op": "reset", "text": prefix})
        keys = "hvyi" if mode == "second" else "woxlxtykyu"
        steps = worker.type(keys, fresh=True)
        # Replay each real intermediate state through the same native adapter.
        for step in steps:
            native.render(step["response"])
        state = steps[-1]["response"]
        displayed = state["candidates"]
        index = 1 if mode == "second" else next(i for i, text in enumerate(displayed)
            if text and text != "我想学英语" and "我想学英语".startswith(text))
        selected_text = displayed[index]
        state, _ = worker.request({"op": "select", "index": index})
        native.render(state)
        committed = state["commit"]
        trajectory = [state]
        for _ in range(8):
            if not state["composing"]:
                break
            state, _ = worker.request({"op": "select", "index": 0})
            native.render(state)
            committed += state["commit"]
            trajectory.append(state)
        view = native.request({"op": "render", "state": {"commit": "", "preedit": "", "composing": False, "candidates": []}})
        expected = selected_text if mode == "second" else "我想学英语"
        assert not state["composing"] and committed == expected
        assert view["host_text"] == prefix + expected and not view["has_marked_text"]
        rows.append({"operation": mode, "displayed": selected_text, "trajectory": trajectory, "view": view})
    return rows


class TranslationLoad:
    def __init__(self, worker, cases, log):
        self.worker, self.cases, self.log = worker, cases, log
        self.stop = threading.Event()
        self.started = threading.Event()
        self.error = None
        self.thread = threading.Thread(target=self.run, daemon=True)

    def run(self):
        try:
            index = 0
            while not self.stop.is_set():
                start = time.perf_counter_ns()
                self.started.set()
                rows = self.worker.request([self.cases[index % len(self.cases)]], "input_contention")
                end = time.perf_counter_ns()
                if len(rows) != 1 or rows[0].get("error"):
                    raise RuntimeError(rows)
                self.log.append({"start_ns": start, "end_ns": end, "result": rows[0]})
                index += 1
        except BaseException as error:
            self.error = repr(error)

    def start(self):
        self.thread.start()
        if not self.started.wait(10):
            raise TimeoutError("No translation contention start")

    def close(self):
        self.stop.set()
        self.thread.join(180)
        if self.thread.is_alive():
            raise TimeoutError("Translation did not finish its bounded in-flight request")
        if self.error:
            raise RuntimeError(self.error)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--native", type=Path, required=True)
    parser.add_argument("--translation-python", type=Path)
    parser.add_argument("--model-root", type=Path, default=Path("/tmp/gogaku-benchmark/models"))
    parser.add_argument("--interval-ms", type=float, default=100)
    parser.add_argument("--rounds", type=int, default=3)
    parser.add_argument("--rasterize", action="store_true", help="diagnostic only: synchronously rasterize every key")
    args = parser.parse_args()
    if args.interval_ms <= 0 or args.rounds < 1:
        parser.error("positive interval and rounds required")
    args.output.mkdir(parents=True, exist_ok=False)
    status = {"complete": False, "scope": "Paced API to controlled AppKit layout preparation; optional diagnostic raster, no IMK/display"}
    workers = []
    native = translator = None
    events, passes, translation_events = [], [], []
    try:
        paths = [Path("/tmp/gogaku-ime-benchmark") / family / "manifest.json" for family in ["qingjian", "rime", "libime"]]
        configs, _, manifests = core.load_configs(paths, ["Q0", "R1", "I0"])
        all_cases = json.loads((HERE / "input-engine-cases.json").read_text())["cases"]
        cases = all_cases[::5]
        core.dump(args.output / "inputs.json", {"manifests": manifests, "cases": cases,
            "case_sha256": core.sha(HERE / "input-engine-cases.json"), "runner_sha256": core.sha(__file__),
            "native_source_sha256": core.sha(HERE / "native-text-client.swift"), "native_binary_sha256": core.sha(args.native),
            "rounds": args.rounds, "interval_ms": args.interval_ms, "rasterize": args.rasterize,
            "conditions": ["resident_idle", "real_translation"] if args.translation_python else ["no_translation_materials"]})
        core.dump(args.output / "environment-before.json", core.host_info())
        native = NativeClient(args.native, args.output)
        native.rasterize = args.rasterize
        for config in configs:
            workers.append(core.Worker(config, args.output, offline=True))
        core.dump(args.output / "startup.json", {w.config["id"]: {"ready": w.ready, "resources": w.resources()} for w in workers})
        core.dump(args.output / "contracts.json", {w.config["id"]: contracts(w, native) for w in workers})
        load_cases = [case for case in json.loads((HERE / "translation-cases.json").read_text())
                      if case["id"] in ["en-sentence", "zh-sentence", "en-long", "zh-long"]]
        if args.translation_python:
            config = {**translation.CONFIGS["opus-ct2-int8-t2"], "python_executable": str(args.translation_python)}
            translator = translation.Worker(config, args.model_root, args.output / "translation.stderr.log")
            core.dump(args.output / "translation-startup.json", translator.ready)
            translator.request(load_cases[:2], "warmup")
        # Pre-warm core and offscreen raster before formal events.
        for worker in workers:
            for case in cases:
                for step in worker.type(case["keys"]):
                    native.render(step["response"])
        for round_index in range(args.rounds):
            order = workers[round_index % len(workers):] + workers[:round_index % len(workers)]
            for worker in order:
                conditions = [False, True] if translator else [False]
                if round_index % 2:
                    conditions.reverse()
                for busy in conditions:
                    condition = "real_translation" if busy else "resident_idle" if translator else "no_translation_materials"
                    load = TranslationLoad(translator, load_cases, translation_events) if busy else None
                    record = {"round": round_index, "config": worker.config["id"], "condition": condition,
                              "environment": core.host_info(), "resources_before": worker.resources()}
                    start_index = len(events)
                    try:
                        if load:
                            load.start()
                        for case in cases:
                            worker.request({"op": "reset"})
                            native.request({"op": "reset"})
                            scheduled = time.perf_counter_ns()
                            for index, key in enumerate(case["keys"]):
                                scheduled += int(args.interval_ms * 1e6)
                                wait = (scheduled - time.perf_counter_ns()) / 1e9
                                if wait > 0:
                                    time.sleep(wait)
                                dispatched = time.perf_counter_ns()
                                state, rtt = worker.request({"op": "key", "key": ord(key)})
                                view = native.render(state)
                                returned = time.perf_counter_ns()
                                assert not state["commit"] and state["handled"]
                                assert view["has_marked_text"] and view["candidate_text"] == "\n".join(
                                    str(i + 1) + ". " + text for i, text in enumerate(state["candidates"]))
                                events.append({"round": round_index, "config": worker.config["id"], "condition": condition,
                                    "case": case["id"], "step": index, "key": key, "scheduled_ns": scheduled,
                                    "dispatched_ns": dispatched, "returned_ns": returned, "core_ns": state["total_ns"],
                                    "worker_rtt_ns": rtt, "native_ns": view["native_ns"],
                                    "queue_ns": dispatched - scheduled, "pipeline_ns": returned - scheduled})
                    finally:
                        if load:
                            load.close()
                    record["resources_after"] = worker.resources()
                    rows = events[start_index:]
                    record["metrics"] = {field: core.summary([row[field] for row in rows]) for field in
                        ["core_ns", "worker_rtt_ns", "native_ns", "queue_ns", "pipeline_ns"]}
                    passes.append(record)
                    core.dump(args.output / "passes.json", passes)
                    print(json.dumps({"round": round_index, "config": worker.config["id"], "condition": condition,
                                      "n": len(rows), "core": record["metrics"]["core_ns"]}), flush=True)
        core.dump(args.output / "events.json", events)
        core.dump(args.output / "translation-events.json", translation_events)
        summaries = {}
        for config_id in [w.config["id"] for w in workers]:
            summaries[config_id] = {}
            for condition in sorted({row["condition"] for row in events}):
                rows = [row for row in events if row["config"] == config_id and row["condition"] == condition]
                expected = sum(len(case["keys"]) for case in cases) * args.rounds
                assert len(rows) == expected, (config_id, condition, len(rows), expected)
                for round_index in range(args.rounds):
                    for case in cases:
                        actual = [row for row in rows if row["round"] == round_index and row["case"] == case["id"]]
                        assert [(r["step"], r["key"]) for r in actual] == list(enumerate(case["keys"]))
                if condition == "real_translation":
                    assert translation_events
                    overlapping = sum(any(t["start_ns"] < row["returned_ns"] and t["end_ns"] > row["dispatched_ns"]
                                          for t in translation_events) for row in rows)
                    assert overlapping >= len(rows) * 0.9, ("Insufficient measured overlap", overlapping, len(rows))
                summaries[config_id][condition] = {field: core.summary([row[field] for row in rows]) for field in
                    ["core_ns", "worker_rtt_ns", "native_ns", "queue_ns", "pipeline_ns"]}
        core.dump(args.output / "summary.json", {"configs": summaries, "total_key_events": len(events),
            "translation_requests": len(translation_events), "scope": status["scope"], "event_coverage_verified": True})
        status["complete"] = True
    except BaseException as error:
        status["error"] = type(error).__name__ + ": " + str(error)
        raise
    finally:
        core.dump(args.output / "events.json", events)
        core.dump(args.output / "translation-events.json", translation_events)
        errors = []
        for resource in [*workers, native, translator]:
            if resource:
                try:
                    if resource is translator:
                        resource.stop()
                    resource.close()
                except Exception as error:
                    errors.append(repr(error))
        if errors:
            status["close_errors"] = errors
            status["complete"] = False
        core.dump(args.output / "environment-after.json", core.host_info())
        core.dump(args.output / "status.json", status)
    if not status["complete"]:
        raise RuntimeError(status)


if __name__ == "__main__":
    main()
