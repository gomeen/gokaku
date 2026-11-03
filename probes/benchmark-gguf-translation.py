#!/usr/bin/env python3
"""Measure isolated CPU GGUF translation: fixed cases, raw responses and macOS RSS."""
import argparse
import ctypes
import datetime
import hashlib
import json
import platform
import socket
import subprocess
import threading
import time
import urllib.error
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / "probes/results/gguf-translation"


class Usage(ctypes.Structure):
    # Darwin sys/resource.h rusage_info_v0; times are nanoseconds, sizes bytes.
    _fields_ = [("uuid", ctypes.c_ubyte * 16)] + [(name, ctypes.c_uint64) for name in (
        "userTime", "systemTime", "idleWakeups", "interruptWakeups", "pageins",
        "wiredBytes", "rssBytes", "footprintBytes", "startTime", "exitTime")]


LIBPROC = ctypes.CDLL("/usr/lib/libproc.dylib")
LIBPROC.proc_pid_rusage.argtypes = [ctypes.c_int, ctypes.c_int, ctypes.c_void_p]
LIBPROC.proc_pid_rusage.restype = ctypes.c_int


def usage(pid):
    value = Usage()
    if LIBPROC.proc_pid_rusage(pid, 0, ctypes.byref(value)) != 0:
        return None
    return {name: getattr(value, name) for name in (
        "rssBytes", "footprintBytes", "userTime", "systemTime", "pageins")}


def request(port, path, data=None, timeout=60):
    body = None if data is None else json.dumps(data, ensure_ascii=False).encode()
    req = urllib.request.Request("http://127.0.0.1:%d%s" % (port, path), data=body,
                                 headers={"Content-Type": "application/json"})
    # Local inference never goes through configured network proxies.
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
    with opener.open(req, timeout=timeout) as response:
        return json.load(response)


def prompt(model, case):
    target = "Chinese" if case["direction"] == "en-zh" else "English"
    if model in ("hy-18b",):
        instruction = ("将以下文本翻译为中文，注意只需要输出翻译后的结果，不要额外解释：" if target == "Chinese"
                       else "Translate the following segment into English, without additional explanation.")
    else:
        language = "中文" if target == "Chinese" else "英语"
        instruction = "请将以下文本翻译为%s，直接输出翻译结果，不要进行任何解释。" % language
    return [{"role": "user", "content": instruction + "\n\n" + case["source"]}]


def atomic_json(path, value):
    temporary = path.with_suffix(".writing")
    temporary.write_text(json.dumps(value, ensure_ascii=False, indent=2) + "\n")
    temporary.replace(path)


def run_model(args, artifact, server, cases, key, cases_sha256):
    model = artifact["id"]
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        port = sock.getsockname()[1]
    command = [str(server), "-m", artifact["path"], "--host", "127.0.0.1", "--port", str(port),
               "-ngl", "0", "-t", str(args.threads), "-tb", str(args.threads), "-c", "1024",
               "-np", "1", "-b", "128", "-ub", "128", "--jinja", "--no-webui",
               "--cache-ram", "0", "--ctx-checkpoints", "0",
               "--chat-template-kwargs", '{"enable_thinking":false}']
    result = {"model": model, "artifact": artifact, "command": command, "cases": [],
              "warmup": [], "peakSampledRssBytes": 0, "peakSampledFootprintBytes": 0,
              "casesSha256": cases_sha256, "threads": args.threads}
    stop = threading.Event()
    start = time.perf_counter()
    with (OUT / (model + ".server.log")).open("w") as log:
        process = subprocess.Popen(command, stdout=log, stderr=log)
        def monitor():
            while not stop.wait(0.05):
                sample = usage(process.pid)
                if sample:
                    result["peakSampledRssBytes"] = max(result["peakSampledRssBytes"], sample["rssBytes"])
                    result["peakSampledFootprintBytes"] = max(result["peakSampledFootprintBytes"], sample["footprintBytes"])
                    if max(sample["rssBytes"], sample["footprintBytes"]) > args.memory_limit_gib * 1024 ** 3:
                        result["memoryLimitExceeded"] = True
                        process.terminate()
                        return
        watcher = threading.Thread(target=monitor, daemon=True)
        watcher.start()
        try:
            deadline = start + 120
            while True:
                if process.poll() is not None:
                    raise RuntimeError("server exited at load: %s" % process.returncode)
                try:
                    if request(port, "/health", timeout=2).get("status") == "ok":
                        break
                except (urllib.error.URLError, TimeoutError):
                    pass
                if time.perf_counter() > deadline:
                    raise TimeoutError("server startup exceeded 120 seconds")
                time.sleep(0.2)
            result["processToReadyMs"] = (time.perf_counter() - start) * 1000
            result["readyUsage"] = usage(process.pid)
            result["props"] = request(port, "/props")
            print(model, "loaded", result["readyUsage"], flush=True)
            warmups = [next(c for c in cases if c["direction"] == d) for d in ("zh-en", "en-zh")]
            for phase, selected in [("warmup", warmups), ("measure", cases)]:
                for case in selected:
                    body = {"model": model, "messages": prompt(model, case), "temperature": 0,
                            "max_tokens": 128, "stream": False, "seed": 42, "cache_prompt": False,
                            "chat_template_kwargs": {"enable_thinking": False}}
                    before = usage(process.pid)
                    began = time.perf_counter()
                    response = request(port, "/v1/chat/completions", body, timeout=60)
                    elapsed = (time.perf_counter() - began) * 1000
                    after = usage(process.pid)
                    choice = response["choices"][0]
                    output = choice["message"].get("content") or ""
                    reasoning = choice["message"].get("reasoning_content") or ""
                    row = {"id": case["id"], "source": case["source"], "direction": case["direction"],
                           "output": output, "reasoning": reasoning, "totalMs": elapsed,
                           "truncated": choice.get("finish_reason") != "stop",
                           "request": body, "response": response, "usageAfter": after}
                    if before and after:
                        row["cpuMs"] = ((after["userTime"] + after["systemTime"])
                                        - (before["userTime"] + before["systemTime"])) / 1e6
                        row["averageCpuPercent"] = row["cpuMs"] / elapsed * 100
                    result["warmup" if phase == "warmup" else "cases"].append(row)
                    atomic_json(OUT / (key + ".json"), result)
                    print(key, phase, case["id"], round(elapsed), output, flush=True)
            result["idleUsage"] = usage(process.pid)
            idle_start = time.perf_counter()
            time.sleep(1)
            idle_after = usage(process.pid)
            if result["idleUsage"] and idle_after:
                initial = result["idleUsage"]
                result["idleCpuPercent"] = ((idle_after["userTime"] + idle_after["systemTime"])
                                            - (initial["userTime"] + initial["systemTime"])) / 1e9 / (time.perf_counter() - idle_start) * 100
            result["status"] = "complete"
        except Exception as error:
            result["status"] = "failed"
            result["error"] = repr(error)
            print(model, "FAILED", repr(error), flush=True)
        finally:
            stop.set()
            watcher.join(timeout=2)
            if process.poll() is None:
                process.terminate()
                try:
                    process.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait(timeout=5)
            result["exitCode"] = process.returncode
            atomic_json(OUT / (key + ".json"), result)
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--models", nargs="+", default=["qwen-05b", "index-2b", "hy-18b"])
    parser.add_argument("--threads", type=int, default=2)
    parser.add_argument("--memory-limit-gib", type=float, default=6)
    parser.add_argument("--tag", default="", help="Result key suffix, e.g. t4 for a 4-thread variant")
    args = parser.parse_args()
    manifest = json.loads((OUT / "artifacts.json").read_text())
    server = next(Path(manifest["runtime"]["directory"]).rglob("llama-server"))
    cases_path = ROOT / "probes/translation-comparison-cases.json"
    cases = json.loads(cases_path.read_text())
    run = {"createdAt": datetime.datetime.now(datetime.timezone.utc).isoformat(),
           "casesSha256": hashlib.sha256(cases_path.read_bytes()).hexdigest(),
           "platform": platform.platform(), "threads": args.threads, "contextTokens": 1024,
           "batchTokens": 128, "maxOutputTokens": 128, "gpuLayers": 0,
           "promptProtocol": {"index-2b": "官方翻译 prompt＋enable_thinking=false；greedy 为实验变体",
                              "hy-18b": "官方 ZH↔XX 指令句式；greedy 为实验变体（官方推荐采样参数未用）",
                              "qwen-05b": "ChatML 默认模板＋翻译指令；官方无专项翻译 prompt",
                              "qwen3-06b": "Qwen3 模板 enable_thinking=false＋翻译指令；官方 Q8_0"},
           "timingScope": "HTTP serialization + tokenization/prompt prefill + full decode + response parse; no loading",
           "memoryScope": "Darwin proc_pid_rusage v0 sampled every 50ms; RSS and physical footprint, not exact peak",
           "version": subprocess.run([str(server), "--version"], capture_output=True, text=True).stdout,
           "runtime": manifest["runtime"], "models": {}}
    for model in args.models:
        artifact = next(a for a in manifest["models"] if a["id"] == model)
        key = model + ("-" + args.tag if args.tag else "")
        run["models"][key] = run_model(args, artifact, server, cases, key, run["casesSha256"])
        atomic_json(OUT / "run.json", run)
    if any(v["status"] != "complete" for v in run["models"].values()):
        raise SystemExit(1)


if __name__ == "__main__":
    main()
