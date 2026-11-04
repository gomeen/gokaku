#!/usr/bin/env python3
"""MiniMax-M2.7-highspeed 翻译延迟探针（anthropic-messages API，同 20 句口径）。"""
import json
import os
import statistics
import time
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
KEY = os.environ.get("MINIMAX_API_KEY")
MODEL = os.environ.get("MINIMAX_MODEL", "MiniMax-M2.7-highspeed")
URL = "https://api.minimaxi.com/anthropic/v1/messages"
if not KEY:
    raise SystemExit("missing MINIMAX_API_KEY")

cases = json.loads((ROOT / "probes" / "translation-comparison-cases.json").read_text())

def translate(text, direction):
    target = "简体中文" if direction == "en-zh" else "英文"
    payload = {
        "model": MODEL,
        "max_tokens": 300,
        "temperature": 0,
        "system": "You are a translation engine. Translate the user text. Output ONLY the translation, with no explanations, quotes, or notes.",
        "messages": [{"role": "user", "content": f"Translate to {target}:\n{text}"}],
    }
    request = urllib.request.Request(
        URL, data=json.dumps(payload).encode(),
        headers={"Content-Type": "application/json", "x-api-key": KEY,
                 "anthropic-version": "2023-06-01"})
    started = time.perf_counter()
    with urllib.request.urlopen(request, timeout=90) as response:
        body = json.loads(response.read())
    elapsed = (time.perf_counter() - started) * 1000
    text_out = "".join(b.get("text", "") for b in body.get("content", []) if b.get("type") == "text")
    usage = body.get("usage", {})
    return elapsed, text_out.strip(), usage

records = []
print(f"model={MODEL} cases={len(cases)}（串行，非流式，temperature=0）", flush=True)
for index, case in enumerate(cases):
    try:
        elapsed, output, usage = translate(case["source"], case["direction"])
    except Exception as error:
        print(f"[{index+1:02d}] {case['id']} FAILED: {error}", flush=True)
        records.append({"id": case["id"], "error": repr(error)})
        continue
    records.append({
        "id": case["id"], "direction": case["direction"], "source": case["source"],
        "expected": case.get("reference"), "output": output,
        "milliseconds": round(elapsed, 1),
        "input_tokens": usage.get("input_tokens"), "output_tokens": usage.get("output_tokens"),
    })
    print(f"[{index+1:02d}] {case['id']} {case['direction']} {elapsed:7.1f}ms  {case['source'][:16]} → {output[:24]}", flush=True)

ok = [r for r in records if "milliseconds" in r]
if ok:
    latencies = [r["milliseconds"] for r in ok]
    out_tokens = [r["output_tokens"] for r in ok if r.get("output_tokens")]
    summary = {
        "schemaVersion": 1, "date": "2026-11-04", "model": MODEL, "endpoint": URL,
        "method": "anthropic-messages 非流式串行逐句，temperature=0；key 不落盘",
        "latencyMs": {"min": round(min(latencies), 1), "p50": round(statistics.median(latencies), 1),
                      "max": round(max(latencies), 1), "mean": round(statistics.mean(latencies), 1)},
        "outputTokens": {"min": min(out_tokens), "median": statistics.median(out_tokens), "max": max(out_tokens)} if out_tokens else None,
        "effectiveTokensPerSecond": round(statistics.median(out_tokens) / (statistics.median(latencies) / 1000), 1) if out_tokens else None,
        "records": records,
    }
    out = ROOT / "probes" / "results" / "deepseek-api" / "minimax-m27-highspeed-20cases.json"
    out.write_text(json.dumps(summary, ensure_ascii=False, indent=2) + "\n")
    print(json.dumps(summary["latencyMs"], ensure_ascii=False))
    print("saved:", out)
