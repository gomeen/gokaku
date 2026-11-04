#!/usr/bin/env python3
"""小牛翻译延迟探针（NMT API）。密钥：NIUTRANS_APIKEY 环境变量。"""

import json, os, statistics, time, urllib.request
from pathlib import Path
ROOT = Path(__file__).resolve().parent.parent
def load_cases():
    return json.loads((ROOT / "probes" / "translation-comparison-cases.json").read_text())
def save(name, summary):
    out = ROOT / "probes" / "results" / "deepseek-api" / name
    out.write_text(json.dumps(summary, ensure_ascii=False, indent=2) + "\n")
    print("saved:", out)

KEY = os.environ.get("NIUTRANS_APIKEY")
if not KEY: raise SystemExit("missing NIUTRANS_APIKEY")
URL = "https://api.niutrans.com/NMTTransAsJson"

def translate(text, direction):
    payload = json.dumps({"src_text": text,
                          "from": "zh" if direction == "zh-en" else "en",
                          "to": "en" if direction == "zh-en" else "zh",
                          "apikey": KEY}).encode()
    request = urllib.request.Request(URL, data=payload,
        headers={"Content-Type": "application/json"})
    started = time.perf_counter()
    with urllib.request.urlopen(request, timeout=30) as response:
        body = json.loads(response.read())
    elapsed = (time.perf_counter() - started) * 1000
    if body.get("error_msg"):
        raise RuntimeError(body["error_msg"])
    return elapsed, (body.get("tgt_text") or "").strip()

records = []
print("service=niutrans cases=20（串行）", flush=True)
for index, case in enumerate(load_cases()):
    try:
        elapsed, output = translate(case["source"], case["direction"])
    except Exception as error:
        print(f"[{index+1:02d}] {case['id']} FAILED: {error}", flush=True)
        records.append({"id": case["id"], "error": repr(error)}); continue
    records.append({"id": case["id"], "direction": case["direction"], "source": case["source"],
                    "expected": case.get("reference"), "output": output, "milliseconds": round(elapsed,1)})
    print(f"[{index+1:02d}] {case['id']} {case['direction']} {elapsed:7.1f}ms  {case['source'][:16]} → {output[:24]}", flush=True)
ok = [r for r in records if "milliseconds" in r]
lat = [r["milliseconds"] for r in ok]
summary = {"schemaVersion":1, "date":"2026-11-04", "service":"niutrans NMT",
           "latencyMs":{"min":round(min(lat),1),"p50":round(statistics.median(lat),1),
                        "max":round(max(lat),1),"mean":round(statistics.mean(lat),1)}, "records":records}
print(json.dumps(summary["latencyMs"], ensure_ascii=False))
save("niutrans-20cases.json", summary)
