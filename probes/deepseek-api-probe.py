#!/usr/bin/env python3
"""DeepSeek API 翻译延迟探针（2026-11-04，deepseek-chat，与 GGUF 探针同 20 句）。

口径：串行逐句、非流式、temperature=0（贪心等价）、完整 HTTP 请求墙钟时延。
key 从环境变量 DEEPSEEK_API_KEY 读取，不落盘、不进任何产物文件。
"""
import json
import os
import statistics
import time
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
KEY = os.environ.get("DEEPSEEK_API_KEY")
if not KEY:
    raise SystemExit("missing DEEPSEEK_API_KEY")
URL = "https://api.deepseek.com/chat/completions"
MODEL = "deepseek-chat"

cases = json.loads((ROOT / "probes" / "translation-comparison-cases.json").read_text())

def translate(text, direction):
    target = "简体中文" if direction == "en-zh" else "英文"
    payload = {
        "model": MODEL,
        "temperature": 0,
        "stream": False,
        "messages": [
            {"role": "system", "content": "You are a translation engine. Translate the user text. Output ONLY the translation, with no explanations, quotes, or notes."},
            {"role": "user", "content": f"Translate to {target}:\n{text}"},
        ],
    }
    request = urllib.request.Request(
        URL, data=json.dumps(payload).encode(),
        headers={"Content-Type": "application/json", "Authorization": f"Bearer {KEY}"})
    started = time.perf_counter()
    with urllib.request.urlopen(request, timeout=60) as response:
        body = json.loads(response.read())
    elapsed = (time.perf_counter() - started) * 1000
    choice = body["choices"][0]["message"]["content"]
    usage = body.get("usage", {})
    return elapsed, choice.strip(), usage

records = []
print(f"model={MODEL} cases={len(cases)}（串行，非流式，temperature=0）", flush=True)
for index, case in enumerate(cases):
    elapsed, output, usage = translate(case["source"], case["direction"])
    records.append({
        "id": case["id"], "direction": case["direction"], "source": case["source"],
        "expected": case.get("reference"), "output": output,
        "milliseconds": round(elapsed, 1),
        "prompt_tokens": usage.get("prompt_tokens"), "completion_tokens": usage.get("completion_tokens"),
    })
    print(f"[{index+1:02d}] {case['id']} {case['direction']} {elapsed:7.1f}ms  {case['source'][:16]} → {output[:24]}", flush=True)

latencies = [r["milliseconds"] for r in records]
completion_tokens = [r["completion_tokens"] for r in records if r["completion_tokens"]]
summary = {
    "schemaVersion": 1,
    "date": "2026-11-04",
    "model": MODEL,
    "endpoint": URL,
    "method": "非流式串行逐句，temperature=0，完整 HTTP 墙钟时延；key 不落盘",
    "cases": ROOT.name + "/probes/translation-comparison-cases.json（20 句，与 GGUF/CT2 探针同源）",
    "latencyMs": {
        "min": round(min(latencies), 1),
        "p50": round(statistics.median(latencies), 1),
        "max": round(max(latencies), 1),
        "mean": round(statistics.mean(latencies), 1),
    },
    "completionTokens": {"min": min(completion_tokens), "median": statistics.median(completion_tokens), "max": max(completion_tokens)},
    "effectiveTokensPerSecond": round(statistics.median(completion_tokens) / (statistics.median(latencies) / 1000), 1),
    "note": "首条含 TCP＋TLS 握手；串行无并发。与 GGUF 探针（逐句含完整请求）口径一致、与 CT2 worker（进程内，无 HTTP）口径不同。",
    "records": records,
}
out = ROOT / "probes" / "results" / "deepseek-api" / "deepseek-chat-20cases.json"
out.write_text(json.dumps(summary, ensure_ascii=False, indent=2) + "\n")
print(json.dumps({k: summary[k] for k in ("latencyMs", "completionTokens", "effectiveTokensPerSecond")}, ensure_ascii=False))
print("saved:", out)
