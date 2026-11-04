#!/usr/bin/env python3
"""火山翻译（Volcengine TranslateText）延迟探针。

与 GGUF/DeepSeek 探针同 20 句口径；火山 V4 签名（service=translate,
region=cn-north-1），HMAC-SHA256。密钥从环境变量读取，不落盘：
  VOLC_ACCESS_KEY / VOLC_SECRET_KEY
前置条件（见 Bob 文档 bobtranslate.com/service/translate/volcengine.html）：
注册火山引擎 → 实名认证 → 开通机器翻译 → IAM 子用户 + TranslateFullAccess 权限 → 新建密钥。
"""
import hashlib
import hmac
import json
import os
import statistics
import time
import urllib.request
from datetime import datetime, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
AK = os.environ.get("VOLC_ACCESS_KEY")
SK = os.environ.get("VOLC_SECRET_KEY")
if not AK or not SK:
    raise SystemExit("missing VOLC_ACCESS_KEY / VOLC_SECRET_KEY")

HOST = "translate.volcengineapi.com"
REGION = "cn-north-1"
SERVICE = "translate"
CONTENT_TYPE = "application/json"


def sign_request(query: str, body: bytes, now: datetime) -> dict:
    x_date = now.strftime("%Y%m%dT%H%M%SZ")
    date_stamp = x_date[:8]
    canonical_headers = f"content-type:{CONTENT_TYPE}\nhost:{HOST}\nx-date:{x_date}\n"
    signed_headers = "content-type;host;x-date"
    payload_hash = hashlib.sha256(body).hexdigest()
    canonical = f"POST\n/\n{query}\n{canonical_headers}\n{signed_headers}\n{payload_hash}"
    scope = f"{date_stamp}/{REGION}/{SERVICE}/request"

    def hm(key: bytes, msg: str) -> bytes:
        return hmac.new(key, msg.encode(), hashlib.sha256).digest()

    # 火山签名派生密钥不带 TC3 前缀（那是腾讯云 v3 的口径）
    k_date = hm(SK.encode(), date_stamp)
    k_region = hm(k_date, REGION)
    k_service = hm(k_region, SERVICE)
    k_signing = hm(k_service, "request")
    string_to_sign = "\n".join([
        "HMAC-SHA256", x_date, scope, hashlib.sha256(canonical.encode()).hexdigest()])
    signature = hmac.new(k_signing, string_to_sign.encode(), hashlib.sha256).hexdigest()
    authorization = (f"HMAC-SHA256 Credential={AK}/{scope}, "
                     f"SignedHeaders={signed_headers}, Signature={signature}")
    return {"Content-Type": CONTENT_TYPE, "Host": HOST, "X-Date": x_date,
            "Authorization": authorization}


def translate(text: str, direction: str):
    payload = json.dumps({
        "TargetLanguage": "zh" if direction == "en-zh" else "en",
        "SourceLanguage": "en" if direction == "en-zh" else "zh",
        "TextList": [text],
    }).encode()
    query = "Action=TranslateText&Version=2020-06-01"
    headers = sign_request(query, payload, datetime.now(timezone.utc))
    url = f"https://{HOST}/?{query}"
    request = urllib.request.Request(url, data=payload, headers=headers, method="POST")
    started = time.perf_counter()
    with urllib.request.urlopen(request, timeout=30) as response:
        result = json.loads(response.read())
    elapsed = (time.perf_counter() - started) * 1000
    if result.get("ResponseMetadata", {}).get("Error"):
        raise RuntimeError(json.dumps(result["ResponseMetadata"]["Error"], ensure_ascii=False))
    output = result["TranslationList"][0]["Translation"]
    return elapsed, output


cases = json.loads((ROOT / "probes" / "translation-comparison-cases.json").read_text())
records = []
print(f"service=volcengine TranslateText cases={len(cases)}（串行）", flush=True)
for index, case in enumerate(cases):
    try:
        elapsed, output = translate(case["source"], case["direction"])
    except Exception as error:
        print(f"[{index+1:02d}] {case['id']} FAILED: {error}", flush=True)
        records.append({"id": case["id"], "error": repr(error)})
        continue
    records.append({"id": case["id"], "direction": case["direction"],
                    "source": case["source"], "expected": case.get("reference"),
                    "output": output, "milliseconds": round(elapsed, 1)})
    print(f"[{index+1:02d}] {case['id']} {case['direction']} {elapsed:7.1f}ms  {case['source'][:16]} → {output[:24]}", flush=True)

ok = [r for r in records if "milliseconds" in r]
if ok:
    latencies = [r["milliseconds"] for r in ok]
    summary = {"schemaVersion": 1, "date": "2026-11-04", "service": "volcengine TranslateText",
               "latencyMs": {"min": round(min(latencies), 1), "p50": round(statistics.median(latencies), 1),
                             "max": round(max(latencies), 1), "mean": round(statistics.mean(latencies), 1)},
               "records": records}
    out = ROOT / "probes" / "results" / "deepseek-api" / "volcengine-translate-20cases.json"
    out.write_text(json.dumps(summary, ensure_ascii=False, indent=2) + "\n")
    print(json.dumps(summary["latencyMs"], ensure_ascii=False))
    print("saved:", out)
