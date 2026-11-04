#!/usr/bin/env python3
"""百度翻译延迟探针（通用翻译标准版，MD5 签名，QPS=1 限速）。密钥：BAIDU_APPID/BAIDU_SECRET。"""
import hashlib

import json, os, statistics, time, urllib.request, urllib.parse
from pathlib import Path
ROOT = Path(__file__).resolve().parent.parent
def load_cases():
    return json.loads((ROOT / "probes" / "translation-comparison-cases.json").read_text())
def save(name, summary):
    out = ROOT / "probes" / "results" / "deepseek-api" / name
    out.write_text(json.dumps(summary, ensure_ascii=False, indent=2) + "\n")
    print("saved:", out)

APPID = os.environ.get("BAIDU_APPID")
SECRET = os.environ.get("BAIDU_SECRET")
if not APPID or not SECRET: raise SystemExit("missing BAIDU_APPID/BAIDU_SECRET")
URL = "https://fanyi-api.baidu.com/api/trans/vip/translate"

def translate(text, direction):
    salt = str(int(time.time() * 1000))
    sign = hashlib.md5((APPID + text + salt + SECRET).encode()).hexdigest()
    query = urllib.parse.urlencode({"q": text,
        "from": "zh" if direction == "zh-en" else "en",
        "to": "en" if direction == "zh-en" else "zh",
        "appid": APPID, "salt": salt, "sign": sign})
    request = urllib.request.Request(f"{URL}?{query}")
    started = time.perf_counter()
    with urllib.request.urlopen(request, timeout=30) as response:
        body = json.loads(response.read())
    elapsed = (time.perf_counter() - started) * 1000
    if "error_code" in body:
        raise RuntimeError(f"{body['error_code']}: {body.get('error_msg')}")
    return elapsed, body["trans_result"][0]["dst"]

records = []
print("service=baidu translate cases=20（串行，QPS=1 每句间隔 1.2s）", flush=True)
for index, case in enumerate(load_cases()):
    try:
        elapsed, output = translate(case["source"], case["direction"])
    except Exception as error:
        print(f"[{index+1:02d}] {case['id']} FAILED: {error}", flush=True)
        records.append({"id": case["id"], "error": repr(error)}); continue
    records.append({"id": case["id"], "direction": case["direction"], "source": case["source"],
                    "expected": case.get("reference"), "output": output, "milliseconds": round(elapsed,1)})
    print(f"[{index+1:02d}] {case['id']} {case['direction']} {elapsed:7.1f}ms  {case['source'][:16]} → {output[:24]}", flush=True)
    time.sleep(1.2)
ok = [r for r in records if "milliseconds" in r]
lat = [r["milliseconds"] for r in ok]
summary = {"schemaVersion":1, "date":"2026-11-04", "service":"baidu translate (standard)",
           "latencyMs":{"min":round(min(lat),1),"p50":round(statistics.median(lat),1),
                        "max":round(max(lat),1),"mean":round(statistics.mean(lat),1)},
           "note":"QPS=1：逐句间隔 1.2s，墙钟时延为单请求耗时不含间隔", "records":records}
print(json.dumps(summary["latencyMs"], ensure_ascii=False))
save("baidu-20cases.json", summary)
