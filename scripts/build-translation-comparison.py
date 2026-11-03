#!/usr/bin/env python3
"""Run 20 fixed sentences through isolated local models and build an offline page."""
import argparse
import datetime
import hashlib
import json
import platform
import re
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
CACHE = Path.home() / "Library/Caches/Gogaku/models"


def render(data):
    data = json.loads(json.dumps(data))
    data["modelInfo"] = {
        "small100": {"label": "small100", "config": "CT2 · INT8 · 2 线程", "timing": "分词＋推理＋解码"},
        "quickmt": {"label": "quickmt", "config": "CT2 · INT8 · 2 线程", "timing": "分词＋推理＋解码"},
    }
    gguf_dir = ROOT / "probes/results/gguf-translation"
    gguf_labels = {
        "qwen-05b": "Qwen2.5-0.5B", "qwen-05b-t4": "Qwen2.5-0.5B · 4线程",
        "qwen3-06b-t2": "Qwen3-0.6B", "qwen3-06b-t4": "Qwen3-0.6B · 4线程",
        "index-2b": "Index-Translate-2B", "hy-18b": "HY-MT1.5-1.8B",
    }
    gguf_results = {}
    for path in sorted(gguf_dir.glob("*.json")):
        if path.name in ("run.json", "artifacts.json"):
            continue
        result = json.loads(path.read_text())
        key = path.stem
        if result.get("status") != "complete" or key in gguf_results:
            continue
        gguf_results[key] = result
    artifacts = {a["id"]: a for a in json.loads((gguf_dir / "artifacts.json").read_text())["models"]}
    for key, result in gguf_results.items():
        if result["artifact"]["sha256"] != artifacts[result["model"]]["sha256"]:
            raise RuntimeError("GGUF result refers to different weights: " + key)
        if result["casesSha256"] != data["casesSha256"]:
            raise RuntimeError("GGUF results refer to different cases: " + key)
        rows = {r["id"]: r for r in result["cases"]}
        if len(rows) != len(data["cases"]):
            raise RuntimeError("Incomplete GGUF cases: " + key)
        for case in data["cases"]:
            row = rows[case["id"]]
            if row["source"] != case["source"] or row["direction"] != case["direction"]:
                raise RuntimeError("GGUF input mismatch: " + case["id"])
            case["results"][key] = {k: row[k] for k in ("id", "source", "direction", "output", "totalMs", "truncated")}
        command = result["command"]
        threads = command[command.index("-t") + 1]
        quant_match = re.search(r"(I?Q\d+[A-Z0-9_]*)", result["artifact"]["file"].upper())
        quant = quant_match.group(1) if quant_match else "GGUF"
        data["modelInfo"][key] = {
            "label": gguf_labels.get(key, key), "config": "llama.cpp · %s · %s 线程" % (quant, threads),
            "timing": "完整本机 HTTP 请求（含分词与生成）", "runCreatedAt": result.get("createdAt", ""),
            "weightBytes": result["artifact"]["sizeBytes"],
            "peakRssBytes": result["peakSampledRssBytes"],
            "footprintBytes": result["peakSampledFootprintBytes"],
            "idleRssBytes": result["idleUsage"]["rssBytes"],
            "loadMs": result["processToReadyMs"],
        }
    ordered = {k: data["modelInfo"][k] for k in ["small100", "quickmt", "quickmt-beam2", "quickmt-beam4", "quickmt-beam5", "quickmt-beam6", "quickmt-beam10", "qwen-05b", "qwen-05b-t4", "qwen3-06b-t2", "qwen3-06b-t4", "index-2b", "hy-18b"] if k in data["modelInfo"]}
    ordered.update({k: v for k, v in data["modelInfo"].items() if k not in ordered})
    data["modelInfo"] = ordered
    variants_path = ROOT / "probes/results/translation-comparison/ct2-variants.json"
    if variants_path.exists():
        variants = json.loads(variants_path.read_text())
        if variants["casesSha256"] != data["casesSha256"]:
            raise RuntimeError("CT2 variant results refer to different cases")
        for case in data["cases"]:
            for variant in variants["variants"]:
                case["results"][variant["key"]] = variant["results"][case["id"]]
        new_ordered = {}
        for k, v in data["modelInfo"].items():
            new_ordered[k] = v
            if k == "quickmt":
                for variant in variants["variants"]:
                    new_ordered[variant["key"]] = {"label": variant["label"], "config": variant["config"], "timing": "分词＋推理＋解码"}
        data["modelInfo"] = new_ordered
    template = (ROOT / "prototypes/translation-comparison.template.html").read_text()
    assert template.count("__COMPARISON_DATA__") == 1
    serialized = json.dumps(data, ensure_ascii=False, indent=2)
    page = template.replace("__COMPARISON_DATA__", serialized.replace("<", "\\u003c"))
    destination = ROOT / "prototypes/translation-comparison.html"
    destination.write_text(page)
    print("Built " + str(destination), flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--render-only", action="store_true", help="Reuse saved outputs; do not run models")
    parser.add_argument("--python", type=Path, default=CACHE / "small100-gate/venv-ct2/bin/python")
    parser.add_argument("--small100-root", type=Path, default=CACHE / "small100-gate")
    parser.add_argument("--quickmt-root", type=Path, default=CACHE / "quickmt-speed")
    args = parser.parse_args()
    cases_path = ROOT / "probes/translation-comparison-cases.json"
    cases = json.loads(cases_path.read_text())
    assert len(cases) == 20 and len({c["id"] for c in cases}) == 20
    assert all(sum(c["direction"] == d for c in cases) == 10 for d in ("zh-en", "en-zh"))
    output_dir = ROOT / "probes/results/translation-comparison"
    output_dir.mkdir(parents=True, exist_ok=True)
    if args.render_only:
        data = json.loads((output_dir / "comparison.json").read_text())
        if data["casesSha256"] != hashlib.sha256(cases_path.read_bytes()).hexdigest():
            raise RuntimeError("Cases changed; rerun inference before rendering")
        render(data)
        return
    records, workers = {}, {}
    for backend, direction, model_root in [
        ("small100", "both", args.small100_root),
        ("quickmt", "zh-en", args.quickmt_root),
        ("quickmt", "en-zh", args.quickmt_root),
    ]:
        name = backend + "-" + direction
        selected = [c for c in cases if direction == "both" or c["direction"] == direction]
        # Each direction gets a warmup; it is excluded from displayed results.
        warmup = [next(c for c in selected if c["direction"] == d)
                  for d in sorted({c["direction"] for c in selected})]
        payload = "\n".join(json.dumps(r, ensure_ascii=False) for r in [
            {"phase": "warmup", "cases": warmup},
            {"phase": "compare", "cases": selected},
            {"event": "stop"},
        ]) + "\n"
        print("Running " + name, flush=True)
        command = [str(args.python), str(ROOT / "probes/translation-backend-worker.py"),
                   "--backend", backend, "--direction", direction, "--root", str(model_root),
                   "--compute-type", "int8", "--threads", "2", "--beam", "1",
                   "--max-decoding-length", "256"]
        completed = subprocess.run(command, input=payload, text=True, capture_output=True, timeout=120)
        (output_dir / (name + ".jsonl")).write_text(completed.stdout)
        (output_dir / (name + ".stderr.log")).write_text(completed.stderr)
        if completed.returncode:
            raise RuntimeError("Worker failed; see " + str(output_dir / (name + ".stderr.log")))
        events = [json.loads(line) for line in completed.stdout.splitlines() if line.strip()]
        workers[name] = next(e for e in events if e["event"] == "ready")
        rows = [e for e in events if e["event"] == "result" and e["phase"] == "compare"]
        if len(rows) != len(selected) or any(e.get("error") for e in rows):
            raise RuntimeError("Incomplete or failed translations: " + name)
        for row in rows:
            records.setdefault(row["id"], {})[backend] = row
    data = {
        "createdAt": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "platform": platform.platform(),
        "casesSha256": hashlib.sha256(cases_path.read_bytes()).hexdigest(),
        "config": {"computeType": "int8", "threads": 2, "beam": 1, "maxDecodingLength": 256},
        "workers": workers,
        "cases": [{**c, "results": records[c["id"]]} for c in cases],
    }
    serialized = json.dumps(data, ensure_ascii=False, indent=2)
    (output_dir / "comparison.json").write_text(serialized + "\n")
    render(data)


if __name__ == "__main__":
    main()
