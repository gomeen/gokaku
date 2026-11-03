#!/usr/bin/env python3
"""Summarise unified translation backend benchmark runs into decision artifacts.

Reads one or more run dirs (run.json + requests.jsonl written by
probes/benchmark-translation-backends.py) and writes models.json, latency.json,
resource.json, quality-gate.json, quality-review.md and environment.json.

2026-11-03 revision (round 2 evaluation fixes):
  - multiple --run-dir inputs merge rows (first dir is the primary for identity,
    resource and environment; quality/latency see the union)
  - the latency gate reads real budget results; missing budget data is reported
    as incomplete and can never count as pass
  - outcomes are counted separately: candidate-released, semantic-qualified,
    safety-fallback and error-released
  - failed requests keep their wall-clock wait and budget-overrun records
  - semantic review must cover every released translate case; missing review
    keeps the gate blocked instead of complete
  - preserve cases report label conformance only; the benchmark never claims
    real-input typo/gibberish detection from expectedAction labels
  - every claimed case must have exactly `rounds` rows per (run, backend); an
    interrupted final round fails summarisation instead of looking complete

The review file is optional. It records semantic judgements a mechanical check
cannot make (names, meaning drift, user policy). Without it the gate is
reported as blocked pending review, never as passed.
"""
import argparse
import hashlib
import importlib.util
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
# Suites whose rows participate in quality counting. `speed` is timing-only;
# `language` is the future-language latency probe.
QUALITY_SUITES = ("risk", "holdout", "short", "confirm")
SCRIPT_EXPECTED = {"en-zh": "Z", "zh-en": "E"}
ERROR_CATEGORIES = ("meaning-error", "omission", "addition", "fragment", "unnatural")


def load_expected_counts():
    """Single source of truth: frozen dataset sizes live in the benchmark driver."""
    spec = importlib.util.spec_from_file_location(
        "gogaku_benchmark_driver", ROOT / "probes/benchmark-translation-backends.py"
    )
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module.EXPECTED_COUNTS


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


def failed_wait(row):
    """User-visible wait of a failed/capped request: model total when present,
    otherwise the parent-measured wall wait recorded for the failure."""
    if row.get("totalMs") is not None:
        return row["totalMs"]
    return row.get("ipcRequestMs")


def wait_over_budget(row, budgets):
    budget = budgets.get(row.get("timingBucket"))
    if budget is None or row.get("expectedAction") != "translate":
        return None
    wait = failed_wait(row)
    if wait is None:
        return None
    return round(wait - budget, 2) if wait > budget else None


def build_latency(run_by_id, rows):
    """Latency report over merged rows. Budget buckets come from the speed
    suite; failed waits are kept and counted, never silently dropped."""
    parameters = run_by_id[0][0]["parameters"]
    budgets = {"short-expression": 500.0, "short-sentence": 2000.0}
    report = {
        "schemaVersion": 2,
        "runIds": [run["runId"] for run, _ in run_by_id],
        "parameters": parameters,
        "budgetsMs": budgets,
        "budgetBasis": "速度子集热态请求；成功 p95 与失败等待都不得超预算。",
        "backends": {},
    }
    for backend, backend_rows in group(rows, lambda row: row["backend"]).items():
        report["backends"][backend] = {"directions": {}}
        for direction, direction_rows in group(backend_rows, lambda row: row["direction"]).items():
            direction_report = {
                "buckets": {}, "budget": {}, "byKind": {}, "bySuite": {},
                "layers": {}, "failures": {}, "overBudget": [],
            }
            for bucket, bucket_rows in group(direction_rows, lambda row: row["timingBucket"]).items():
                direction_report["buckets"][bucket] = bucket_entry(bucket_rows, budgets.get(bucket))
            speed_rows = [row for row in direction_rows if row.get("suite") == "speed"]
            for bucket, bucket_rows in group(speed_rows, lambda row: row["timingBucket"]).items():
                direction_report["budget"][bucket] = bucket_entry(bucket_rows, budgets.get(bucket), is_budget=True)
            for kind, kind_rows in group(direction_rows, lambda row: row["kindClass"]).items():
                direction_report["byKind"][kind] = stats([row["totalMs"] for row in measured(kind_rows)])
            for suite, suite_rows in group(direction_rows, lambda row: row["suite"]).items():
                direction_report["bySuite"][suite] = stats([row["totalMs"] for row in measured(suite_rows)])
            failed_rows = [
                row for row in direction_rows
                if row.get("expectedAction") == "translate"
                and (row.get("error") or not row.get("generated"))
                and failed_wait(row) is not None
            ]
            direction_report["failures"] = {
                "note": "生成失败或被长度上限截断的请求；等待时间单独保留，不计入成功生成延迟。",
                "count": len(failed_rows),
                "waitMs": stats([failed_wait(row) for row in failed_rows]),
                "cases": sorted({row["caseId"] for row in failed_rows}),
            }
            over = []
            for row in direction_rows:
                exceed = wait_over_budget(row, budgets)
                if exceed is not None:
                    over.append({
                        "caseId": row["caseId"],
                        "suite": row.get("suite"),
                        "direction": direction,
                        "bucket": row.get("timingBucket"),
                        "waitMs": round(failed_wait(row), 2),
                        "budgetMs": budgets.get(row.get("timingBucket")),
                        "exceededMs": exceed,
                        "generated": bool(row.get("generated")),
                        "truncated": bool(row.get("truncated")),
                        "errorType": row.get("errorType"),
                        "runId": row.get("runId"),
                        "round": row.get("round"),
                    })
            over.sort(key=lambda item: -item["exceededMs"])
            direction_report["overBudget"] = over[:40]
            direction_report["overBudgetCount"] = len(over)
            direction_report["overBudgetCases"] = sorted({item["caseId"] for item in over})
            preserve_rows = [row for row in direction_rows if row.get("expectedAction") == "preserve"]
            direction_report["preservePolicy"] = {
                "cases": len(preserve_rows),
                "generated": sum(1 for row in preserve_rows if row.get("generated")),
                "truncated": sum(1 for row in preserve_rows if row.get("truncated")),
                "latencyMs": stats([row["totalMs"] for row in preserve_rows if row.get("totalMs") is not None]),
                "note": "策略应保留输入；生产不调用翻译。这里只记录模型若被调用的行为，不计入翻译延迟预算，也不作为真实识别能力的证据。",
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


def bucket_entry(bucket_rows, budget, is_budget=False):
    success = measured(bucket_rows)
    entry = stats([row["totalMs"] for row in success])
    entry["budgetMs"] = budget
    failed = [
        row for row in bucket_rows
        if row.get("expectedAction") == "translate"
        and (row.get("error") or not row.get("generated"))
        and failed_wait(row) is not None
    ]
    entry["failed"] = {
        "count": len(failed),
        "waitMs": stats([failed_wait(row) for row in failed]),
        "overBudgetCount": sum(1 for row in failed if budget is not None and failed_wait(row) > budget),
    }
    if budget is None:
        entry["pass"] = None
        entry["status"] = "no-budget"
    elif not success and not failed:
        entry["pass"] = None
        entry["status"] = "missing-data"
    else:
        over_failed = entry["failed"]["overBudgetCount"]
        entry["pass"] = bool(entry.get("p95") is not None and entry["p95"] <= budget and over_failed == 0)
        entry["status"] = "pass" if entry["pass"] else "fail"
        if over_failed:
            entry["status"] += "+failed-over-budget"
    if is_budget:
        entry["basis"] = "speed-suite；成功 p95 ≤ 预算且失败等待不得超预算"
    return entry


def build_resource(run, rows, models):
    report = {
        "schemaVersion": 1,
        "runId": run["runId"],
        "workers": {},
        "totals": {},
        "directionSwitch": {},
        "environment": run.get("environment", {}),
        "notes": "RSS 为进程 ru_maxrss 峰值；本轮未单独采样稳定驻留内存，不能把峰值当作长期常驻。资源统计只来自主运行目录。",
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


def judge_case(backend, case_id, direction, released_rows, review, checks):
    """One released translate case -> (error_released, pending_review, notes).

    A recorded manual review governs (fail => error, pass => qualified).
    Without a review entry the mechanical check governs, but the case is also
    marked pending: a missing review can never be reported as complete.
    """
    notes = []
    manual = None if review is None else (review.get("cases") or {}).get("%s:%s" % (backend, case_id))
    if manual is not None:
        if manual.get("status") == "fail":
            if manual.get("category"):
                notes.append("category:" + str(manual.get("category")))
            return True, False, notes
        return False, False, notes
    error = False
    for row in released_rows:
        case_for_check = {"id": case_id, "direction": direction, "expectedAction": "translate"}
        auto = semantic_check(case_for_check, row.get("output"), row.get("hardening"), checks)
        if auto.get("status") == "fail" and not auto.get("manual"):
            error = True
            notes.extend("missing:" + item for item in auto.get("missing", []))
            notes.extend("forbidden:" + item for item in auto.get("forbidden", []))
    return error, True, notes + ["review-missing"]


def empty_suite_stats():
    return {
        "translateCases": 0, "preserveCases": 0,
        "candidateReleased": 0, "semanticQualified": 0, "semanticPending": 0,
        "errorReleased": 0, "safetyFallback": 0, "modelError": 0,
        "errorReleasedIds": [], "pendingIds": [], "fallbackOnlyIds": [],
        "reviewRequired": 0, "reviewed": 0, "reviewMissingIds": [],
    }


def add_suite_stats(target, source):
    for key, value in source.items():
        if isinstance(value, list):
            target[key].extend(value)
        else:
            target[key] += value


def assert_dataset_counts(runs, rows, expected_counts):
    """Fail loudly when a run claims a suite its rows do not actually cover."""
    problems = []
    claimed = set()
    for run, run_rows in runs:
        counts = run.get("caseCounts") or {}
        if not counts:
            problems.append("run %s has no caseCounts" % run["runId"])
            continue
        claimed |= set(counts)
        for suite, recorded in counts.items():
            expected = expected_counts.get(suite)
            if expected is None:
                continue
            total = recorded["total"] if isinstance(recorded, dict) else recorded
            if total != expected["total"]:
                problems.append(
                    "run %s suite %s: %s cases, expected %d"
                    % (run["runId"], suite, total, expected["total"])
                )
    # Union coverage: every quality-suite case the runs claim must actually
    # have request rows in the merged data (runs may split suites across dirs).
    seen = {}
    for row in rows:
        suite = row.get("suite")
        if suite in QUALITY_SUITES:
            seen.setdefault((suite, row["direction"]), set()).add(row["caseId"])
    for suite in sorted(claimed & set(QUALITY_SUITES)):
        expected = expected_counts.get(suite)
        if not expected:
            continue
        for direction, per_direction in expected.items():
            if direction == "total":
                continue
            got = seen.get((suite, direction), set())
            if len(got) != per_direction:
                problems.append(
                    "suite %s %s: %d cases have request rows, expected %d"
                    % (suite, direction, len(got), per_direction)
                )
    # Round multiplicity: each claimed case must have exactly `rounds` rows per
    # (run, backend); an interrupted final round can never be summarized as a
    # completed evaluation.
    per_run_rounds = {run["runId"]: run.get("parameters", {}).get("rounds") for run, _ in runs}
    per_run_claimed = {run["runId"]: set(run.get("caseCounts") or {}) for run, _ in runs}
    row_rounds = {}
    for row in rows:
        suite = row.get("suite")
        if suite in QUALITY_SUITES or suite == "speed":
            key = (row.get("runId"), row.get("backend"), suite, row["caseId"])
            row_rounds[key] = row_rounds.get(key, 0) + 1
    for (run_id, backend, suite, case_id), count in sorted(row_rounds.items(), key=str):
        if suite not in per_run_claimed.get(run_id, set()):
            continue
        rounds = per_run_rounds.get(run_id)
        if rounds is not None and count != rounds:
            problems.append(
                "run %s %s suite %s case %s: %d rounds of rows, expected %s"
                % (run_id, backend, suite, case_id, count, rounds)
            )
    for run, _ in runs:
        if run.get("completeRun") is False:
            problems.append("run %s recorded an incomplete run" % run["runId"])
    if problems:
        raise SystemExit("dataset assertion failed: " + "; ".join(problems))
    return sorted(claimed & set(QUALITY_SUITES))


def build_quality(primary_run, runs, rows, review, latency, expected_counts):
    checks = load_json(RISK_CHECKS_PATH)["cases"]
    risk_cases = {case["id"]: case for case in load_json(RISK_PATH)}
    covered_suites = assert_dataset_counts(runs, rows, expected_counts)
    missing_quality_suites = [suite for suite in QUALITY_SUITES if suite not in covered_suites]
    report = {
        "schemaVersion": 2,
        "runIds": [run["runId"] for run, _ in runs],
        "parameters": primary_run["parameters"],
        "qualitySuitesCovered": covered_suites,
        "qualitySuitesMissing": missing_quality_suites,
        "userBlindTest": "not-run",
        "agentSemanticReview": "recorded" if review else "missing",
        "reviewMetadata": None if review is None else {
            "reviewedAt": review.get("reviewedAt"),
            "reviewer": review.get("reviewer"),
            "method": review.get("method"),
            "scoringRules": review.get("scoringRules"),
        },
        "thresholds": {"usableRate": 0.95, "shortExpressionP95Ms": 500, "shortSentenceP95Ms": 2000},
        "outcomeLegend": {
            "candidateReleased": "至少一轮输出通过加固层进入默认候选",
            "semanticQualified": "进入候选且逐轮语义审阅合格（审阅可推翻机械信号）",
            "semanticPending": "进入候选但缺少对应人工审阅记录",
            "errorReleased": "错误/不自然译文通过了加固层进入候选（含机械语义失败未被审阅推翻）",
            "safetyFallback": "加固层回退原文，错误译文未进入候选",
            "modelError": "运行错误或空输出，无候选",
            "preserveCases": "策略应保留输入；按 expectedAction 标签分组，只统计标签一致性",
        },
        "backends": {},
    }
    for backend, backend_rows in group(rows, lambda row: row["backend"]).items():
        backend_report = {"directions": {}, "suites": {}, "risk": [], "reviewIndex": []}
        report["backends"][backend] = backend_report
        # Judge every (direction, suite, case) once; reuse for direction totals,
        # suite rollups and the gate so numbers cannot drift apart.
        judged = {}  # direction -> suite -> stats
        for direction, direction_rows in group(backend_rows, lambda row: row["direction"]).items():
            if direction not in SCRIPT_EXPECTED:
                continue
            per_suite = {}
            for suite in QUALITY_SUITES:
                suite_rows = [row for row in direction_rows if row.get("suite") == suite]
                if not suite_rows:
                    continue
                cases = {}
                for row in suite_rows:
                    cases.setdefault(row["caseId"], []).append(row)
                stats_entry = empty_suite_stats()
                for case_id, case_rows in sorted(cases.items()):
                    released = [
                        row for row in case_rows
                        if (row.get("hardening") or {}).get("verdict") in ("candidate", "candidate-normalized")
                    ]
                    if case_rows[0].get("expectedAction") == "preserve":
                        stats_entry["preserveCases"] += 1
                        continue
                    stats_entry["translateCases"] += 1
                    if released:
                        stats_entry["candidateReleased"] += 1
                        stats_entry["reviewRequired"] += 1
                        manual = None if review is None else (review.get("cases") or {}).get("%s:%s" % (backend, case_id))
                        if manual is not None:
                            stats_entry["reviewed"] += 1
                        else:
                            stats_entry["reviewMissingIds"].append(case_id)
                        error, pending, _notes = judge_case(backend, case_id, direction, released, review, checks)
                        if error:
                            stats_entry["errorReleased"] += 1
                            stats_entry["errorReleasedIds"].append(case_id)
                        elif pending:
                            stats_entry["semanticPending"] += 1
                            stats_entry["pendingIds"].append(case_id)
                        else:
                            stats_entry["semanticQualified"] += 1
                    elif any(row.get("error") for row in case_rows):
                        stats_entry["modelError"] += 1
                    else:
                        stats_entry["safetyFallback"] += 1
                        stats_entry["fallbackOnlyIds"].append(case_id)
                per_suite[suite] = stats_entry
            judged[direction] = per_suite

        for direction, per_suite in judged.items():
            direction_totals = empty_suite_stats()
            for suite_stats in per_suite.values():
                add_suite_stats(direction_totals, suite_stats)
            # Legacy mechanical view (first occurrence per case) for continuity
            # with the round-1 report; the outcome counts above are authoritative.
            quality_rows = [row for row in backend_rows if row.get("direction") == direction and row.get("suite") in QUALITY_SUITES]
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
                "basis": "每用例首轮输出（与第一轮报告口径一致）；逐轮结果以上方 outcomes 统计为准",
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
                "outcomes": {
                    key: (list(direction_totals[key]) if isinstance(direction_totals[key], list) else direction_totals[key])
                    for key in direction_totals if not key.endswith("Ids")
                },
                "reviewCoverage": {
                    "required": direction_totals["reviewRequired"],
                    "reviewed": direction_totals["reviewed"],
                    "missingIds": sorted(direction_totals["reviewMissingIds"]),
                },
                "preservePolicy": {
                    "cases": direction_totals["preserveCases"],
                    "labelConformance": sum(
                        1 for row in preserve_rows if (row.get("hardening") or {}).get("verdict") == "preserve-expected"
                    ),
                    "basis": "expectedAction 测试标签只用于评分分组与策略一致性核对；本基准不能证明真实输入时已能识别错拼/乱码，真实识别能力需要不经标签的运行时验证。",
                },
            }
            backend_report["directions"][direction] = mechanical

        if not backend_report["directions"]:
            backend_report["gate"] = {
                "verdict": "not-applicable",
                "note": "质量门槛只定义于中英方向；本运行是未来语言延迟探针。",
            }
            continue
        if all(item["translateCases"] == 0 for item in backend_report["directions"].values()):
            backend_report["gate"] = {
                "verdict": "not-applicable",
                "note": "本运行只有速度子集，未包含质量样本。",
            }
            continue

        # Risk review index is deduplicated by case; request-level rows stay in JSONL.
        risk_by_case = {}
        for row in backend_rows:
            if row.get("suite") != "risk":
                continue
            case = dict(risk_cases.get(row["caseId"], {}))
            case["expectedAction"] = row.get("expectedAction", "translate")
            semantic = semantic_check(case, row.get("output"), row.get("hardening"), checks)
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
                "runId": row.get("runId"),
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
        backend_report["risk"] = list(risk_by_case.values())
        backend_report["reviewIndex"] = list(risk_by_case.values())

        # Per-suite outcome roll-up (directions merged) for the gate.
        suite_rollup = {}
        for suite in QUALITY_SUITES:
            suite_totals = empty_suite_stats()
            found = False
            for direction, per_suite in judged.items():
                if per_suite.get(suite):
                    found = True
                    add_suite_stats(suite_totals, per_suite[suite])
            if found:
                suite_rollup[suite] = suite_totals
        backend_report["suites"] = suite_rollup

        gate_risk = sorted(suite_rollup.get("risk", {}).get("errorReleasedIds", []))
        all_error = sorted({
            case_id
            for suite in suite_rollup.values()
            for case_id in suite["errorReleasedIds"]
        })
        manual_pending = sorted({
            case_id
            for suite in suite_rollup.values()
            for case_id in suite["pendingIds"]
        })
        review_required = sum(suite.get("candidateReleased", 0) for suite in suite_rollup.values())
        review_missing = sorted({
            case_id
            for mechanical in backend_report["directions"].values()
            for case_id in mechanical["reviewCoverage"]["missingIds"]
        })
        backend_report["gate"] = {
            "usableRate": min(
                (direction["usableRate"] for direction in backend_report["directions"].values()),
                default=0,
            ),
            "usableRatePass": all(
                direction["usableRate"] >= 0.95
                for direction in backend_report["directions"].values()
            ),
            "unhandledRisk": gate_risk,
            "unhandledRiskCount": len(gate_risk),
            "errorReleased": {
                "count": len(all_error),
                "cases": all_error,
            },
            "manualPending": manual_pending,
            "reviewCoverage": {
                "required": review_required,
                "reviewFile": "missing" if review is None else "present",
                "missingIds": review_missing,
                "missingCount": len(review_missing),
                "complete": review is not None and not review_missing,
                "note": "每个进入候选的应译用例都必须有人工审阅记录；缺失审阅不能报完成。",
            },
            "userBlindTest": "not-run",
        }

    # Attach latency budget results and decide a conservative verdict.
    for backend, backend_report in report["backends"].items():
        gate = backend_report.get("gate") or {}
        if gate.get("verdict") == "not-applicable":
            continue
        latency_report = (latency.get("backends") or {}).get(backend) or {}
        budget_status = []
        budget_detail = {}
        for direction, direction_report in (latency_report.get("directions") or {}).items():
            entries = direction_report.get("budget") or {}
            if not entries:
                budget_detail[direction] = {"status": "incomplete", "reason": "no speed-suite budget data"}
                budget_status.append("incomplete")
                continue
            for bucket in ("short-expression", "short-sentence"):
                entry = entries.get(bucket)
                if entry is None:
                    budget_detail["%s/%s" % (direction, bucket)] = {"status": "incomplete", "reason": "bucket missing"}
                    budget_status.append("incomplete")
                else:
                    status = entry.get("status") or "incomplete"
                    budget_detail["%s/%s" % (direction, bucket)] = {
                        "status": status,
                        "p95": entry.get("p95"),
                        "budgetMs": entry.get("budgetMs"),
                        "failed": entry.get("failed"),
                    }
                    budget_status.append(status)
        over_cases = sorted({
            item["caseId"]
            for direction_report in (latency_report.get("directions") or {}).values()
            for item in direction_report.get("overBudget") or []
        })
        over_count = sum(
            direction_report.get("overBudgetCount") or 0
            for direction_report in (latency_report.get("directions") or {}).values()
        )
        if any(status.startswith("fail") for status in budget_status):
            gate["latencyBudget"] = "fail"
        elif "incomplete" in budget_status or not budget_status:
            gate["latencyBudget"] = "incomplete"
        else:
            gate["latencyBudget"] = "pass"
        gate["latencyBudgetDetail"] = budget_detail
        gate["latencyOverBudget"] = {
            "count": over_count,
            "cases": over_cases,
            "note": "任何应译请求（成功或失败）等待超过该输入长度档预算都会记录在案；有超限记录不得报通过。",
        }
        if gate["unhandledRiskCount"] > 0:
            gate["verdict"] = "fail-unhandled-risk"
        elif gate["errorReleased"]["count"] > 0:
            gate["verdict"] = "fail-error-released"
        elif not gate["usableRatePass"]:
            gate["verdict"] = "fail-mechanical-usable-rate"
        elif missing_quality_suites:
            gate["verdict"] = "blocked-incomplete-coverage"
            gate["note"] = "冻结质量套件未全部覆盖：" + "、".join(missing_quality_suites)
        elif gate["latencyBudget"] == "fail":
            gate["verdict"] = "fail-latency-budget"
        elif gate["latencyBudget"] == "incomplete":
            gate["verdict"] = "blocked-incomplete-latency"
        elif gate["manualPending"] or not gate["reviewCoverage"]["complete"] or report["userBlindTest"] != "pass":
            gate["verdict"] = "blocked-pending-review"
        elif gate["latencyOverBudget"]["count"] > 0:
            gate["verdict"] = "pass-with-latency-overruns"
        else:
            gate["verdict"] = "pass-mechanical"
    return report


def write_quality_review(report, path):
    lines = [
        "# 翻译后端统一实测：质量审阅索引",
        "",
        "本文件由 `scripts/summarize-translation-backends.py` 生成，列出原始输出、加固处置和逐套件结果统计；",
        "不是用户盲测结论。人工语义判断记录在 `semantic-review` 文件中。",
        "",
        "口径：`候选放行`＝输出通过加固层进入默认候选；`语义合格`＝候选且审阅合格；",
        "`错误放行`＝错误译文进入候选；`安全回退`＝加固层回退原文（不是译文）；",
        "`应保留`用例按测试标签分组，只统计标签一致性，不代表真实识别能力。",
        "",
    ]
    for backend, backend_report in report["backends"].items():
        lines.extend(["## " + backend, ""])
        gate = backend_report.get("gate") or {}
        if gate.get("verdict") == "not-applicable":
            lines.append("门槛：`%s` — %s" % (gate.get("verdict"), gate.get("note")))
            lines.append("")
            continue
        for suite, suite_stats in sorted((backend_report.get("suites") or {}).items()):
            lines.append("### 套件 `%s` 结果统计" % suite)
            lines.append("")
            lines.append("| 应译 | 候选放行 | 语义合格 | 语义待审 | 错误放行 | 安全回退 | 运行错误 | 应保留 |")
            lines.append("| ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |")
            lines.append(
                "| {translateCases} | {candidateReleased} | {semanticQualified} | {semanticPending} "
                "| {errorReleased} | {safetyFallback} | {modelError} | {preserveCases} |".format(**suite_stats)
            )
            for label, key in (("错误放行", "errorReleasedIds"), ("语义待审", "pendingIds"), ("仅安全回退", "fallbackOnlyIds")):
                ids = suite_stats.get(key) or []
                if ids:
                    lines.append("- %s：%s" % (label, "、".join("`%s`" % cid for cid in ids[:40]) + ("…" if len(ids) > 40 else "")))
            lines.append("")
        for entry in backend_report["risk"]:
            lines.append("### 风险用例 `%s` — %s" % (entry["caseId"], entry["direction"]))
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
        for key in ("usableRate", "usableRatePass", "latencyBudget", "latencyOverBudget",
                    "unhandledRisk", "errorReleased", "manualPending", "reviewCoverage", "verdict"):
            lines.append("- %s: `%s`" % (key, json.dumps(gate.get(key), ensure_ascii=False)))
        lines.append("")
    path.write_text("\n".join(lines) + "\n")


def load_run_dir(run_dir):
    run = load_json(run_dir / "run.json")
    rows = read_jsonl(run_dir / "requests.jsonl")
    return run, rows


def check_worker_compatibility(primary, extra):
    """Merged runs must use the same worker identities, or the old scores are invalid."""
    problems = []
    for name, entry in extra.get("workers", {}).items():
        primary_entry = primary.get("workers", {}).get(name)
        if primary_entry is None:
            problems.append("worker %s missing from primary run" % name)
            continue
        for key in ("backend", "direction", "root"):
            if entry["spec"].get(key) != primary_entry["spec"].get(key):
                problems.append(
                    "worker %s spec %s: %r != primary %r"
                    % (name, key, entry["spec"].get(key), primary_entry["spec"].get(key))
                )
        if entry.get("pin") != primary_entry.get("pin"):
            problems.append("worker %s pin mismatch: %r != %r" % (name, entry.get("pin"), primary_entry.get("pin")))
    for key in ("threads", "computeType", "beam", "maxDecodingLength"):
        if extra.get("parameters", {}).get(key) != primary.get("parameters", {}).get(key):
            problems.append(
                "parameter %s: %r != primary %r"
                % (key, extra.get("parameters", {}).get(key), primary.get("parameters", {}).get(key))
            )
    if problems:
        raise SystemExit("run compatibility check failed: " + "; ".join(problems))


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--run-dir", type=Path, action="append",
                        help="run directory(s); repeat to merge, first is primary")
    parser.add_argument("--review", type=Path)
    parser.add_argument("--skip-hashes", action="store_true")
    parser.add_argument("--output-dir", type=Path,
                        help="where to write artifacts (default: primary run dir)")
    args = parser.parse_args()

    run_dirs = args.run_dir or [ROOT / "probes/results/translation-backends"]
    run_dirs = [path.resolve() for path in run_dirs]
    runs = [load_run_dir(run_dir) for run_dir in run_dirs]
    primary_run, primary_rows = runs[0]
    for extra_run, _ in runs[1:]:
        check_worker_compatibility(primary_run, extra_run)
    all_rows = [row for _, rows in runs for row in rows]
    output_dir = args.output_dir.resolve() if args.output_dir else run_dirs[0]
    review = load_json(args.review) if args.review else None
    expected_counts = load_expected_counts()
    models = build_models(primary_run, skip_hashes=args.skip_hashes)
    latency = build_latency(runs, all_rows)
    resource = build_resource(primary_run, primary_rows, models)
    quality = build_quality(primary_run, runs, all_rows, review, latency, expected_counts)
    environment = {
        "schemaVersion": 1,
        "runId": primary_run["runId"],
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
        "run": primary_run.get("environment", {}),
        "workerVersions": {name: entry["ready"].get("versions") for name, entry in primary_run["workers"].items()},
    }
    output_dir.mkdir(parents=True, exist_ok=True)
    for name, value in [
        ("models.json", models),
        ("latency.json", latency),
        ("resource.json", resource),
        ("quality-gate.json", quality),
        ("environment.json", environment),
    ]:
        (output_dir / name).write_text(json.dumps(value, ensure_ascii=False, indent=1) + "\n")
    write_quality_review(quality, output_dir / "quality-review.md")
    print(json.dumps({
        "runIds": [run["runId"] for run, _ in runs],
        "rows": len(all_rows),
        "outputDir": str(output_dir),
        "backends": {
            backend: backend_report["gate"]
            for backend, backend_report in quality["backends"].items()
        },
    }, ensure_ascii=False, indent=1))
    return 0


if __name__ == "__main__":
    sys.exit(main())
