#!/usr/bin/env python3
"""Summarise the unified translation backend benchmark into decision artifacts.

Reads run.json + requests.jsonl (written by probes/benchmark-translation-backends.py)
and writes models.json, latency.json, resource.json, quality-gate.json,
quality-review.md and environment.json next to the raw run.

The review file is optional. It records semantic judgements that a mechanical
check cannot make (names, meaning drift, user policy). Without it the gate is
reported as blocked pending review, never as passed.
"""
import argparse
import hashlib
import json
import math
import os
import platform
import re
import statistics
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
RISK_PATH = ROOT / "probes/translation-cases.json"
RISK_CHECKS_PATH = ROOT / "probes/translation-risk-checks.json"
BUDGETS = {"short-expression": 500.0, "short-sentence": 2000.0}
SCRIPT_EXPECTED = {"en-zh": "Z", "zh-en": "E"}


def read_jsonl(path):
    rows = []
    with path.open() as handle:
        for line in handle:
            line = line.strip()
            if line:
                rows.append(json.loads(line))
    return rows


def percentile(values, q):
    if not values:
        return None
    ordered = sorted(values)
    index = max(0, math.ceil(q * len(ordered)) - 1)
    return ordered[index]


def stats(values, digits=2):
    values = [value for value in values if value is not None]
    if not values:
        return {"n": 0}
    return {
        "n": len(values),
        "min": round(min(values), digits),
        "p50": round(percentile(values, 0.50), digits),
        "p95": round(percentile(values, 0.95), digits),
        "p99": round(percentile(values, 0.99), digits),
        "max": round(max(values), digits),
        "mean": round(statistics.mean(values), digits),
    }


def file_sha256(path):
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def file_manifest(paths):
    files = []
    for path in sorted(paths):
        if not path.is_file():
            continue
        files.append(
            {
                "path": str(path),
                "bytes": path.stat().st_size,
                "sha256": file_sha256(path),
            }
        )
    return files


def dir_bytes(path):
    if not path.exists():
        return 0
    return sum(p.stat().st_size for p in path.rglob("*") if p.is_file())


def model_files(worker_name, run):
    ready = run["workers"][worker_name]["ready"]
    identity = ready.get("identity", {})
    root = Path(identity.get("sourceDir") or identity.get("modelDir") or run["workers"][worker_name]["spec"]["root"])
    if identity.get("backend") == "small100":
        source = Path(identity["sourceDir"])
        model_dir = Path(identity["modelDir"])
        names = ["config.json", "vocab.json", "sentencepiece.bpe.model", "tokenizer_config.json",
                 "special_tokens_map.json", "tokenization_small100.py", "model.safetensors", "README.md"]
        files = file_manifest([source / name for name in names])
        files += file_manifest([model_dir / name for name in ["config.json", "model.bin", "shared_vocabulary.json"]])
        artifact = [model_dir / name for name in ["config.json", "model.bin", "shared_vocabulary.json"]]
        artifact += [source / name for name in ["vocab.json", "sentencepiece.bpe.model", "tokenizer_config.json",
                                                "special_tokens_map.json", "tokenization_small100.py", "config.json"]]
        return files, sum(path.stat().st_size for path in artifact if path.is_file()), root
    model_dir = Path(identity["modelDir"])
    names = ["model.bin", "src.spm.model", "tgt.spm.model", "config.json",
             "source_vocabulary.json", "target_vocabulary.json", "README.md"]
    files = file_manifest([model_dir / name for name in names])
    artifact = [model_dir / name for name in ["model.bin", "src.spm.model", "tgt.spm.model", "config.json",
                                              "source_vocabulary.json", "target_vocabulary.json"]]
    return files, sum(path.stat().st_size for path in artifact if path.is_file()), model_dir


def build_models(run, skip_hashes=False):
    models = {"schemaVersion": 1, "runId": run["runId"], "pins": {}, "workers": {}, "totalArtifactBytes": 0}
    for name, entry in run["workers"].items():
        identity = dict(entry["ready"]["identity"])
        pin = entry.get("pin", {})
        for key in ("repository", "revision", "license"):
            if pin.get(key) and key not in identity:
                identity[key] = pin[key]
        files, artifact_bytes, root = model_files(name, run)
        if skip_hashes:
            for item in files:
                item.pop("sha256", None)
        models["pins"][name] = pin
        root_bytes = dir_bytes(root)
        if identity.get("backend") == "small100" and identity.get("modelDir"):
            model_dir = Path(identity["modelDir"])
            if model_dir != root:
                root_bytes += dir_bytes(model_dir)
        models["workers"][name] = {
            "identity": identity,
            "root": str(root),
            "artifactBytes": artifact_bytes,
            "rootBytes": root_bytes,
            "files": files,
            "versions": entry["ready"].get("versions", {}),
        }
        models["totalArtifactBytes"] += artifact_bytes
    return models


def group(rows, key):
    buckets = {}
    for row in rows:
        buckets.setdefault(key(row), []).append(row)
    return buckets


def measured(rows, translate_only=True):
    selected = [
        row for row in rows
        if row.get("error") is None and row.get("generated") and row.get("totalMs") is not None
    ]
    if translate_only:
        selected = [row for row in selected if row.get("expectedAction") == "translate"]
    return selected


def build_latency(run, rows):
    report = {
        "schemaVersion": 1,
        "runId": run["runId"],
        "parameters": run["parameters"],
        "budgetsMs": BUDGETS,
        "backends": {},
    }
    for backend, backend_rows in group(rows, lambda row: row["backend"]).items():
        report["backends"][backend] = {"directions": {}}
        for direction, direction_rows in group(backend_rows, lambda row: row["direction"]).items():
            direction_report = {"buckets": {}, "budget": {}, "byKind": {}, "bySuite": {}, "layers": {}}
            for bucket, bucket_rows in group(direction_rows, lambda row: row["timingBucket"]).items():
                values = [row["totalMs"] for row in measured(bucket_rows)]
                entry = stats(values)
                budget = BUDGETS.get(bucket)
                entry["budgetMs"] = budget
                entry["pass"] = bool(entry.get("p95") is not None and budget is not None and entry["p95"] <= budget)
                direction_report["buckets"][bucket] = entry
            speed_rows = [row for row in direction_rows if row.get("suite") == "speed"]
            for bucket, bucket_rows in group(speed_rows, lambda row: row["timingBucket"]).items():
                values = [row["totalMs"] for row in measured(bucket_rows)]
                entry = stats(values)
                budget = BUDGETS.get(bucket)
                entry["budgetMs"] = budget
                entry["pass"] = bool(entry.get("p95") is not None and budget is not None and entry["p95"] <= budget)
                direction_report["budget"][bucket] = entry
            for kind, kind_rows in group(direction_rows, lambda row: row["kindClass"]).items():
                direction_report["byKind"][kind] = stats([row["totalMs"] for row in measured(kind_rows)])
            for suite, suite_rows in group(direction_rows, lambda row: row["suite"]).items():
                direction_report["bySuite"][suite] = stats([row["totalMs"] for row in measured(suite_rows)])
            preserve_rows = [row for row in direction_rows if row.get("expectedAction") == "preserve"]
            direction_report["preservePolicy"] = {
                "cases": len(preserve_rows),
                "generated": sum(1 for row in preserve_rows if row.get("generated")),
                "truncated": sum(1 for row in preserve_rows if row.get("truncated")),
                "latencyMs": stats([row["totalMs"] for row in preserve_rows if row.get("totalMs") is not None]),
                "note": "策略应保留输入；生产不调用翻译。这里只记录模型若被调用的行为，不计入翻译延迟预算。",
            }
            direction_report["layers"] = {
                "modelTotalMs": stats([row["totalMs"] for row in measured(direction_rows)]),
                "ipcRequestMs": stats([row["ipcRequestMs"] for row in measured(direction_rows)]),
                "ipcOverheadMs": stats([row["ipcOverheadMs"] for row in measured(direction_rows)]),
                "hardeningMs": stats([(row.get("hardening") or {}).get("ms") for row in measured(direction_rows)]),
                "encodeMs": stats([row.get("encodeMs") for row in measured(direction_rows)]),
                "generateMs": stats([row.get("generateMs") for row in measured(direction_rows)]),
                "decodeMs": stats([row.get("decodeMs") for row in measured(direction_rows)]),
                "cpuMs": stats([row.get("cpuMs") for row in measured(direction_rows)]),
            }
            report["backends"][backend]["directions"][direction] = direction_report
    return report


def build_resource(run, rows, models):
    report = {
        "schemaVersion": 1,
        "runId": run["runId"],
        "workers": {},
        "totals": {},
        "directionSwitch": {},
        "environment": run.get("environment", {}),
        "notes": "RSS 为进程 ru_maxrss 峰值；本轮未单独采样稳定驻留内存，不能把峰值当作长期常驻。",
    }
    total_peak = 0
    for name, entry in run["workers"].items():
        ready = entry["ready"]
        worker_rows = [row for row in rows if row["worker"] == name]
        peak = max([ready.get("peakRssBytes") or 0] + [row.get("peakRssBytes") or 0 for row in worker_rows])
        total_peak += peak
        cpu_ratios = [
            row["cpuMs"] / row["totalMs"]
            for row in measured(worker_rows, translate_only=False)
            if row.get("cpuMs") is not None and row.get("totalMs")
        ]
        report["workers"][name] = {
            "identity": ready.get("identity"),
            "versions": ready.get("versions"),
            "modelLoadMs": ready.get("modelLoadMs"),
            "processStartToReadyMs": ready.get("processStartToReadyMs"),
            "readyPeakRssBytes": ready.get("peakRssBytes"),
            "peakRssBytes": peak,
            "artifactBytes": models["workers"].get(name, {}).get("artifactBytes"),
            "rootBytes": models["workers"].get(name, {}).get("rootBytes"),
            "cpuToWallRatio": stats(cpu_ratios),
            "requestCount": len(worker_rows),
        }
    report["totals"] = {
        "peakRssBytes": total_peak,
        "artifactBytes": models["totalArtifactBytes"],
        "workerCount": len(run["workers"]),
    }
    report["warmup"] = {}
    for unit, entry in (run.get("warmup") or {}).items():
        warmup_rows = entry.get("rows") or []
        first = warmup_rows[0] if warmup_rows else {}
        report["warmup"][unit] = {
            "status": "error" if entry.get("error") else "ok",
            "warmupBatchIpcMs": entry.get("ipcMs"),
            "firstRequestTotalMs": first.get("totalMs"),
            "rowCount": len(warmup_rows),
            "note": "预热不计入热态延迟统计；首个请求单独保留。",
        }
    # Direction switching: small100 shares weights; quickmt loads a second model.
    for backend in ("small100", "quickmt"):
        backend_rows = [row for row in rows if row["backend"] == backend]
        if not backend_rows:
            continue
        if backend == "small100":
            switch_values = []
            same_values = []
            previous = None
            for row in backend_rows:
                if row.get("totalMs") is None or row.get("expectedAction") != "translate":
                    continue
                if previous is not None and previous != row["direction"]:
                    switch_values.append(row["totalMs"])
                elif previous == row["direction"]:
                    same_values.append(row["totalMs"])
                previous = row["direction"]
            report["directionSwitch"][backend] = {
                "sharedWeights": True,
                "switchRequiresModelLoad": False,
                "firstAfterDirectionChangeMs": stats(switch_values),
                "sameDirectionMs": stats(same_values),
            }
        else:
            loads = {
                name: entry["ready"].get("modelLoadMs")
                for name, entry in run["workers"].items()
                if name.startswith("quickmt-")
            }
            report["directionSwitch"][backend] = {
                "sharedWeights": False,
                "switchRequiresModelLoad": True,
                "perDirectionLoadMs": loads,
                "note": "两个方向各自加载模型；切换方向需加载另一份模型（约见 perDirectionLoadMs），或同时常驻。",
            }
    return report


def load_json(path):
    return json.loads(path.read_text())


def semantic_check(case, output, hardening, checks):
    check = checks.get(case.get("id"))
    if not check or check.get("policy") == "preserve" or case.get("expectedAction") == "preserve":
        return {"status": "not-applicable"}
    text = ((hardening or {}).get("normalizedOutput") or output or "").lower()
    missing = [needle for needle in check.get("requireAll", []) if needle.lower() not in text]
    for group in check.get("requireAny", []):
        if not any(needle.lower() in text for needle in group):
            missing.append("one-of:" + "|".join(group))
    forbidden = [needle for needle in check.get("forbid", []) if needle.lower() in text]
    return {
        "status": "pass" if not missing and not forbidden else "fail",
        "manual": bool(check.get("manual")),
        "missing": missing,
        "forbidden": forbidden,
    }


def build_quality(run, rows, review=None):
    checks = load_json(RISK_CHECKS_PATH)["cases"]
    risk_cases = {case["id"]: case for case in load_json(RISK_PATH)}
    report = {
        "schemaVersion": 1,
        "runId": run["runId"],
        "parameters": run["parameters"],
        "userBlindTest": "not-run",
        "agentSemanticReview": "pending" if review is None else "recorded",
        "reviewMetadata": None if review is None else {
            "reviewedAt": review.get("reviewedAt"),
            "reviewer": review.get("reviewer"),
            "method": review.get("method"),
        },
        "thresholds": {"usableRate": 0.95, "shortExpressionP95Ms": 500, "shortSentenceP95Ms": 2000},
        "backends": {},
    }
    for backend, backend_rows in group(rows, lambda row: row["backend"]).items():
        report["backends"][backend] = {"directions": {}, "risk": [], "reviewIndex": []}
        for direction, direction_rows in group(backend_rows, lambda row: row["direction"]).items():
            if direction not in SCRIPT_EXPECTED:
                continue
            quality_rows = [row for row in direction_rows if row.get("suite") != "speed"]
            deduped = {}
            for row in quality_rows:
                deduped.setdefault((row.get("caseId"), row.get("direction")), row)
            quality_rows = list(deduped.values())
            translate_rows = [row for row in quality_rows if row.get("expectedAction") == "translate"]
            preserve_rows = [row for row in quality_rows if row.get("expectedAction") == "preserve"]
            usable = [row for row in translate_rows if (row.get("hardening") or {}).get("verdict") in ("candidate", "candidate-normalized")]
            model_available = [row for row in translate_rows if row.get("generated") and not row.get("truncated") and not row.get("error")]
            counts = {}
            reasons = {}
            for row in translate_rows:
                verdict = (row.get("hardening") or {}).get("verdict", "unknown")
                counts[verdict] = counts.get(verdict, 0) + 1
                if verdict not in ("candidate", "candidate-normalized", "preserve-expected"):
                    reason = (row.get("hardening") or {}).get("reason", "unknown")
                    reasons[reason] = reasons.get(reason, 0) + 1
            mechanical = {
                "translateCases": len(translate_rows),
                "modelAvailable": len(model_available),
                "modelAvailableRate": round(len(model_available) / max(1, len(translate_rows)), 4),
                "usable": len(usable),
                "usableRate": round(len(usable) / max(1, len(translate_rows)), 4),
                "verdictCounts": counts,
                "fallbackReasons": reasons,
                "preserveCases": len(preserve_rows),
                "preservePolicySatisfied": sum(1 for row in preserve_rows if (row.get("hardening") or {}).get("verdict") == "preserve-expected"),
                "empty": sum(1 for row in translate_rows if (row.get("hardening") or {}).get("verdict") == "empty"),
                "error": sum(1 for row in translate_rows if row.get("error")),
                "truncated": sum(1 for row in translate_rows if row.get("truncated")),
            }
            report["backends"][backend]["directions"][direction] = mechanical

        if not report["backends"][backend]["directions"]:
            report["backends"][backend]["gate"] = {
                "verdict": "not-applicable",
                "note": "质量门槛只定义于中英方向；本运行是未来语言延迟探针。",
            }
            continue
        if all(item["translateCases"] == 0 for item in report["backends"][backend]["directions"].values()):
            report["backends"][backend]["gate"] = {
                "verdict": "not-applicable",
                "note": "本运行只有速度子集，未包含风险集/保留集质量样本。",
            }
            continue

        # Risk review index is deduplicated by case; request-level rows stay in JSONL.
        risk_by_case = {}
        for row in backend_rows:
            if row.get("suite") != "risk":
                continue
            case = risk_cases.get(row["caseId"], {})
            case_for_check = dict(case)
            case_for_check["expectedAction"] = row.get("expectedAction", "translate")
            semantic = semantic_check(case_for_check, row.get("output"), row.get("hardening"), checks)
            review_entry = None
            if review:
                review_entry = (review.get("cases") or {}).get("%s:%s" % (backend, row["caseId"]))
            entry = {
                "caseId": row["caseId"],
                "direction": row["direction"],
                "kind": row.get("kind"),
                "source": row.get("source"),
                "reviewNote": case.get("review"),
                "rawOutput": row.get("output"),
                "hardeningVerdict": (row.get("hardening") or {}).get("verdict"),
                "hardeningReason": (row.get("hardening") or {}).get("reason"),
                "normalizedOutput": (row.get("hardening") or {}).get("normalizedOutput"),
                "semantic": semantic,
                "manualReview": review_entry,
                "latencyMs": row.get("totalMs"),
                "round": row.get("round"),
            }
            existing = risk_by_case.get(row["caseId"])
            if existing is None:
                entry["rounds"] = [row.get("round")]
                entry["outputVariants"] = [row.get("output")]
                risk_by_case[row["caseId"]] = entry
            else:
                existing["rounds"].append(row.get("round"))
                if row.get("output") not in existing["outputVariants"]:
                    existing["outputVariants"].append(row.get("output"))
        report["backends"][backend]["risk"] = list(risk_by_case.values())
        report["backends"][backend]["reviewIndex"] = list(risk_by_case.values())

        # Gate: a candidate with an unreviewed semantic failure blocks.
        # A recorded manual review can confirm (fail) or override (pass).
        unhandled_auto = []
        manual_pending = []
        reviewed_failures = []
        for entry in report["backends"][backend]["risk"]:
            if entry["hardeningVerdict"] not in ("candidate", "candidate-normalized"):
                continue
            semantic = entry["semantic"]
            review_entry = entry.get("manualReview")
            if review_entry:
                if review_entry.get("status") == "fail":
                    reviewed_failures.append(entry)
            elif semantic.get("status") == "fail":
                if semantic.get("manual"):
                    manual_pending.append(entry)
                else:
                    unhandled_auto.append(entry)
            elif semantic.get("manual"):
                manual_pending.append(entry)
        unhandled_ids = sorted({entry["caseId"] for entry in unhandled_auto + reviewed_failures})
        report["backends"][backend]["gate"] = {
            "usableRate": min(
                (direction["usableRate"] for direction in report["backends"][backend]["directions"].values()),
                default=0,
            ),
            "usableRatePass": all(
                direction["usableRate"] >= 0.95
                for direction in report["backends"][backend]["directions"].values()
            ),
            "unhandledRisk": unhandled_ids,
            "unhandledRiskCount": len(unhandled_ids),
            "manualPending": sorted({entry["caseId"] for entry in manual_pending}),
            "reviewedRiskFailures": sorted({entry["caseId"] for entry in reviewed_failures}),
            "userBlindTest": "not-run",
        }

    # Attach latency budget results and decide a conservative verdict.
    for backend, backend_report in report["backends"].items():
        if (backend_report.get("gate") or {}).get("verdict") == "not-applicable":
            continue
        backend_rows = [row for row in rows if row["backend"] == backend]
        budget_ok = True
        for direction, direction_report in backend_report["directions"].items():
            for bucket, entry in (direction_report.get("budget") or {}).items():
                if entry.get("p95") is not None and not entry.get("pass"):
                    budget_ok = False
        gate = backend_report["gate"]
        gate["latencyBudgetPass"] = budget_ok
        if gate["unhandledRiskCount"] > 0:
            gate["verdict"] = "fail-unhandled-risk"
        elif not gate["usableRatePass"]:
            gate["verdict"] = "fail-mechanical-usable-rate"
        elif gate["manualPending"] or report["userBlindTest"] == "not-run":
            gate["verdict"] = "blocked-pending-review"
        elif not budget_ok:
            gate["verdict"] = "fail-latency-budget"
        else:
            gate["verdict"] = "pass-mechanical"
    return report


def write_quality_review(report, path):
    lines = [
        "# 翻译后端统一实测：风险集审阅索引",
        "",
        "本文件由 `scripts/summarize-translation-backends.py` 生成，只列原始输出、加固处置和机械语义信号；",
        "不是用户盲测结论。人工语义判断记录在 `semantic-review.md` / `semantic-review.json`。",
        "",
    ]
    for backend, backend_report in report["backends"].items():
        lines.extend(["## " + backend, ""])
        for entry in backend_report["risk"]:
            lines.append("### `%s` — %s" % (entry["caseId"], entry["direction"]))
            lines.append("")
            lines.append("- 源文：`%s`" % (entry.get("source") or ""))
            lines.append("- 审阅提示：%s" % (entry.get("reviewNote") or "无"))
            lines.append("- 原始输出：`%s`" % (entry.get("rawOutput") or ""))
            lines.append("- 加固判定：`%s` / `%s`" % (entry.get("hardeningVerdict"), entry.get("hardeningReason")))
            if entry.get("normalizedOutput"):
                lines.append("- 归一输出：`%s`" % entry["normalizedOutput"])
            semantic = entry.get("semantic") or {}
            lines.append("- 机械语义：`%s`%s" % (semantic.get("status"), "（需人工判读）" if semantic.get("manual") else ""))
            if semantic.get("missing"):
                lines.append("- 未命中：%s" % "、".join("`%s`" % item for item in semantic["missing"]))
            if semantic.get("forbidden"):
                lines.append("- 命中禁词：%s" % "、".join("`%s`" % item for item in semantic["forbidden"]))
            if entry.get("manualReview"):
                lines.append("- 人工审阅：`%s` — %s" % (entry["manualReview"].get("status"), entry["manualReview"].get("note")))
            lines.append("")
        lines.extend(["### 门槛", ""])
        gate = backend_report["gate"]
        for key in ("usableRate", "usableRatePass", "latencyBudgetPass", "unhandledRisk", "manualPending", "verdict"):
            lines.append("- %s: `%s`" % (key, gate.get(key)))
        lines.append("")
    path.write_text("\n".join(lines) + "\n")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--run-dir", type=Path, default=ROOT / "probes/results/translation-backends")
    parser.add_argument("--review", type=Path)
    parser.add_argument("--skip-hashes", action="store_true")
    args = parser.parse_args()
    run_dir = args.run_dir.resolve()
    run = load_json(run_dir / "run.json")
    rows = read_jsonl(run_dir / "requests.jsonl")
    review = load_json(args.review) if args.review else None
    models = build_models(run, skip_hashes=args.skip_hashes)
    latency = build_latency(run, rows)
    resource = build_resource(run, rows, models)
    quality = build_quality(run, rows, review)
    environment = {
        "schemaVersion": 1,
        "runId": run["runId"],
        "host": {
            "platform": platform.platform(),
            "machine": platform.machine(),
            "processor": subprocess.check_output(["sysctl", "-n", "machdep.cpu.brand_string"], text=True).strip()
            if sys.platform == "darwin" else platform.processor(),
            "macos": subprocess.check_output(["sw_vers", "-productVersion"], text=True).strip()
            if sys.platform == "darwin" else None,
            "ncpu": os.cpu_count(),
        },
        "parentPython": sys.version,
        "run": run.get("environment", {}),
        "workerVersions": {name: entry["ready"].get("versions") for name, entry in run["workers"].items()},
    }
    for name, value in [
        ("models.json", models),
        ("latency.json", latency),
        ("resource.json", resource),
        ("quality-gate.json", quality),
        ("environment.json", environment),
    ]:
        (run_dir / name).write_text(json.dumps(value, ensure_ascii=False, indent=1) + "\n")
    write_quality_review(quality, run_dir / "quality-review.md")
    print(json.dumps({
        "runId": run["runId"],
        "rows": len(rows),
        "backends": {
            backend: backend_report["gate"]
            for backend, backend_report in quality["backends"].items()
        },
    }, ensure_ascii=False, indent=1))
    return 0


if __name__ == "__main__":
    sys.exit(main())
