#!/usr/bin/env python3
"""硅基流动翻译延迟探针（默认 Qwen2.5-7B-Instruct 免费档）。密钥：SILICONFLOW_API_KEY。"""

import json, os, statistics, time, urllib.request
from pathlib import Path
ROOT = Path(__file__).resolve().parent.parent
def load_cases():
    return json.loads((ROOT / "probes" / "translation-comparison-cases.json").read_text())
def save(name, summary):
    out = ROOT / "probes" / "results" / "deepseek-api" / name
    out.write_text(json.dumps(summary, ensure_ascii=False, indent=2) + "\n")
    print("saved:", out)

KEY = os.environ.get("SILICONFLOW_API_KEY")
if not KEY: raise SystemExit("missing SILICONFLOW_API_KEY")
URL = "https://api.siliconflow.cn/v1/chat/completions"
MODEL = os.environ.get("SILICONFLOW_MODEL", "Qwen/Qwen2.5-7B-Instruct")

def translate(text, direction):
    target = "简体中文" if direction == "en-zh" else "英文"
    payload = {"model": MODEL, "temperature": 0, "max_tokens": 200,
               "messages": [{"role": "system", "content": "You are a translation engine. Translate the user text. Output ONLY the translation, with no explanations, quotes, or notes."},
                            {"role": "user", "content": f"Translate to {target}:\n{text}"}]}
    request = urllib.request.Request(URL, data=json.dumps(payload).encode(),
        headers={"Content-Type": "application/json", "Authorization": f"Bearer {KEY}"})
    started = time.perf_counter()
    with urllib.request.urlopen(request, timeout=60) as response:
        body = json.loads(response.read())
    elapsed = (time.perf_counter() - started) * 1000
    usage = body.get("usage", {})
    return elapsed, body["choices"][0]["message"]["content"].strip(), usage

records = []
print(f"model={MODEL} cases=20（串行，temperature=0）", flush=True)
for index, case in enumerate(load_cases()):
    try:
        elapsed, output, usage = translate(case["source"], case["direction"])
    except Exception as error:
        print(f"[{index+1:02d}] {case['id']} FAILED: {error}", flush=True)
        records.append({"id": case["id"], "error": repr(error)}); continue
    records.append({"id": case["id"], "direction": case["direction"], "source": case["source"],
                    "expected": case.get("reference"), "output": output, "milliseconds": round(elapsed,1)})
    print(f"[{index+1:02d}] {case['id']} {case['direction']} {elapsed:7.1f}ms  {case['source'][:16]} → {output[:24]}", flush=True)
ok = [r for r in records if "milliseconds" in r]
lat = [r["milliseconds"] for r in ok]
summary = {"schemaVersion":1, "date":"2026-11-04", "model":MODEL,
           "latencyMs":{"min":round(min(lat),1),"p50":round(statistics.median(lat),1),
                        "max":round(max(lat),1),"mean":round(statistics.mean(lat),1)}, "records":records}
print(json.dumps(summary["latencyMs"], ensure_ascii=False))
save("siliconflow-20cases.json", summary)
