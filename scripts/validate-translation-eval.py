#!/usr/bin/env python3
"""Regression asserts for the translation backend evaluation pipeline itself.

The 2026-11-03 round-1 review found that a silently missing dataset and a
latency gate that defaulted to pass could make an incomplete evaluation look
finished. This script pins the guarantees the evaluation must keep:

  1. the frozen 88-item short-text set is really loaded by `all`, and every
     dataset-size assertion fails loudly on tampering;
  2. over-budget latency data can never report pass; missing budget data
     reports incomplete, never pass;
  3. a missing semantic review keeps the gate blocked (never complete), and a
     full review still cannot pass while the user blind test is not run;
  4. a known-bad translation that slipped through the hardening filter is
     counted as error-released, never as semantic-qualified;
  5. preserve cases report label conformance only — the report cannot claim
     real typo/gibberish detection from expectedAction labels.

Pure Python, no models needed; synthetic runs are built in a temp directory.
"""
import importlib.util
import json
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent

PASS = 0
checks_run = []


def check(name):
    def wrap(fn):
        checks_run.append((name, fn))
        return fn
    return wrap


def load_module(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


SUM = load_module("gogaku_summarizer", ROOT / "scripts/summarize-translation-backends.py")
DRIVER = load_module("gogaku_benchmark_driver", ROOT / "probes/benchmark-translation-backends.py")


def make_row(**kw):
    base = {
        "schemaVersion": 1, "runId": "R1", "round": 1, "sequence": 1,
        "backend": "fake", "worker": "fake", "caseId": "case-x", "suite": "speed",
        "direction": "en-zh", "kind": "word", "kindClass": "word",
        "timingBucket": "short-expression", "expectedAction": "translate",
        "source": "hello", "sourceSha256": "0" * 64, "sourceChars": 5,
        "output": "你好", "generated": True, "truncated": False,
        "error": None, "errorType": None,
        "totalMs": 100.0, "cpuMs": 90.0,
        "encodeMs": 5.0, "generateMs": 90.0, "decodeMs": 5.0,
        "ipcRequestMs": 110.0, "ipcOverheadMs": 10.0,
        "budgetMs": 500.0, "budgetExceededMs": None,
        "hardening": {"verdict": "candidate", "reason": "checks-passed", "normalizedOutput": None, "ms": 0.1},
        "semantic": {"status": "pass"},
        "modelIdentity": {"backend": "fake"},
    }
    base.update(kw)
    return base


def make_run(rows, case_counts, rounds=5, run_id="R1"):
    for row in rows:
        row.setdefault("runId", run_id)
    return {
        "schemaVersion": 1,
        "runId": run_id,
        "startedAt": "2026-11-03T00:00:00Z",
        "parameters": {
            "backends": ["fake"], "directions": ["en-zh"], "cases": "all",
            "rounds": rounds, "threads": 2, "computeType": "int8", "beam": 1,
            "maxDecodingLength": 256, "workerPython": "/bin/python3",
            "small100Root": "/tmp", "quickmtRoot": "/tmp",
            "hardeningDylib": None, "languageProbes": "not-run",
        },
        "environment": {"platform": "test"},
        "workers": {
            "fake": {
                "spec": {"backend": "fake", "direction": "both", "root": "/tmp"},
                "pin": {"repository": "fake/model", "revision": "deadbeef", "license": "MIT"},
                "ready": {"identity": {"backend": "fake", "modelDir": "/tmp"}, "versions": {}, "peakRssBytes": 1},
                "stderrLog": "/tmp/x",
            }
        },
        "caseCounts": case_counts,
        "rounds": [],
    }


def counts_for(suites):
    counts = {}
    per = DRIVER.EXPECTED_COUNTS
    for suite in suites:
        expected = per[suite]
        counts[suite] = {
            "total": expected["total"],
            "byDirection": {
                direction: count
                for direction, count in expected.items()
                if direction != "total"
            },
        }
    return counts


def synthetic_expected(suites_per_direction):
    """Dataset counts matching the synthetic rows so assertions pass."""
    out = {}
    for suite, per_direction in suites_per_direction.items():
        total = sum(per_direction.values())
        out[suite] = {"total": total, **per_direction}
    return out


def verdict_of(quality, backend="fake"):
    return quality["backends"][backend]["gate"]


# ── 1. 专项集确实加载 ─────────────────────────────────────────────────────

@check("short-set-loaded")
def test_short_set_loaded():
    _, by_suite = DRIVER.load_cases("all")
    assert set(by_suite) == {"risk", "holdout", "short", "speed"}, by_suite.keys()
    assert len(by_suite["short"]) == 88
    assert sum(1 for c in by_suite["short"] if c["direction"] == "en-zh") == 44
    assert sum(1 for c in by_suite["short"] if c["direction"] == "zh-en") == 44
    _, by_suite = DRIVER.load_cases("short,confirm")
    assert len(by_suite["short"]) == 88 and len(by_suite["confirm"]) == 100
    # The run manifest must record the frozen counts too.
    counts = counts_for(["short", "confirm"])
    assert counts["short"]["total"] == 88 and counts["confirm"]["byDirection"]["en-zh"] == 50
    # Tampering must fail loudly.
    with tempfile.TemporaryDirectory() as tmp:
        original = DRIVER.SHORT_PATH.read_text()
        data = json.loads(original)
        data["cases"] = data["cases"][:-1]  # drop one case: 87 != 88
        tampered = Path(tmp) / "translation-short-expressions.json"
        tampered.write_text(json.dumps(data, ensure_ascii=False))
        DRIVER.SHORT_PATH = tampered
        try:
            try:
                DRIVER.load_cases("all")
            except SystemExit:
                pass
            else:
                raise AssertionError("truncated short set did not fail the loader")
            # direction imbalance must also fail
            data2 = json.loads(original)
            data2["cases"] = [c for c in data2["cases"] if c["direction"] != "zh-en"]
            tampered.write_text(json.dumps(data2, ensure_ascii=False))
            try:
                DRIVER.load_cases("all")
            except SystemExit:
                pass
            else:
                raise AssertionError("direction imbalance did not fail the loader")
        finally:
            DRIVER.SHORT_PATH = ROOT / "validation/translation-short-expressions.json"
    # cross-suite id collision must fail
    with tempfile.TemporaryDirectory() as tmp:
        risk = json.loads(DRIVER.RISK_PATH.read_text())
        short = json.loads(DRIVER.SHORT_PATH.read_text())
        short["cases"][0]["id"] = risk[0]["id"]
        saved_risk, saved_short = DRIVER.RISK_PATH, DRIVER.SHORT_PATH
        DRIVER.RISK_PATH = Path(tmp) / "risk.json"
        DRIVER.SHORT_PATH = Path(tmp) / "short.json"
        DRIVER.RISK_PATH.write_text(json.dumps(risk, ensure_ascii=False))
        DRIVER.SHORT_PATH.write_text(json.dumps(short, ensure_ascii=False))
        try:
            try:
                DRIVER.load_cases("all")
            except SystemExit:
                pass
            else:
                raise AssertionError("cross-suite id collision did not fail the loader")
        finally:
            DRIVER.RISK_PATH, DRIVER.SHORT_PATH = saved_risk, saved_short


# ── 2. 超预算数据不能报通过 ────────────────────────────────────────────

@check("over-budget-cannot-pass")
def test_over_budget_cannot_pass():
    review = {"schemaVersion": 2, "cases": {}}
    for suite in ("risk", "holdout", "short", "confirm"):
        review["cases"]["fake:%s-ok" % suite] = {"status": "pass", "note": "ok"}

    def counts(short_extra=0):
        return synthetic_expected({
            "risk": {"en-zh": 1}, "holdout": {"en-zh": 1},
            "short": {"en-zh": 1 + short_extra}, "confirm": {"en-zh": 1},
        })

    fake_counts = counts()

    def base_rows():
        rows = []
        for suite in ("risk", "holdout", "short", "confirm"):
            rows.append(make_row(
                caseId="%s-ok" % suite, suite=suite, timingBucket="short-expression",
                output="你好", hardening={"verdict": "candidate", "reason": "checks-passed", "normalizedOutput": None},
            ))
        return rows

    # (a) over-budget success rows in the speed suite must fail the budget gate.
    rows = base_rows() + [
        make_row(caseId="speed-1", suite="speed", timingBucket="short-expression", totalMs=600.0),
        make_row(caseId="speed-2", suite="speed", timingBucket="short-expression", totalMs=700.0),
        make_row(caseId="speed-3", suite="speed", timingBucket="short-sentence", totalMs=1500.0),
    ]
    run = make_run(rows, fake_counts | {"speed": {"total": 3, "byDirection": {"en-zh": 3}}})
    latency = SUM.build_latency([(run, rows)], rows)
    entry = latency["backends"]["fake"]["directions"]["en-zh"]["budget"]["short-expression"]
    assert entry["pass"] is False and entry["status"].startswith("fail"), entry
    quality = SUM.build_quality(run, [(run, rows)], rows, review, latency, fake_counts)
    gate = verdict_of(quality)
    assert gate["latencyBudget"] == "fail", gate
    assert gate["verdict"] == "fail-latency-budget", gate

    # (b) a failed request's wait over budget counts too.
    rows = base_rows() + [
        make_row(caseId="speed-1", suite="speed", timingBucket="short-expression",
                 totalMs=None, generated=False, error="repeated", ipcRequestMs=1800.0),
        make_row(caseId="speed-2", suite="speed", timingBucket="short-expression", totalMs=100.0),
        make_row(caseId="speed-3", suite="speed", timingBucket="short-sentence", totalMs=150.0),
    ]
    run = make_run(rows, fake_counts | {"speed": {"total": 3, "byDirection": {"en-zh": 3}}})
    latency = SUM.build_latency([(run, rows)], rows)
    entry = latency["backends"]["fake"]["directions"]["en-zh"]["budget"]["short-expression"]
    assert entry["failed"]["count"] == 1 and entry["failed"]["overBudgetCount"] == 1, entry
    assert entry["pass"] is False
    quality = SUM.build_quality(run, [(run, rows)], rows, review, latency, fake_counts)
    assert verdict_of(quality)["latencyBudget"] == "fail"

    # (c) missing budget data reports incomplete, never pass.
    rows = base_rows()
    run = make_run(rows, fake_counts)
    latency = SUM.build_latency([(run, rows)], rows)
    quality = SUM.build_quality(run, [(run, rows)], rows, review, latency, fake_counts)
    gate = verdict_of(quality)
    assert gate["latencyBudget"] == "incomplete", gate
    assert gate["verdict"] == "blocked-incomplete-latency", gate

    # (d) over-budget waits are recorded on any suite, not just speed.
    rows = base_rows() + [
        make_row(caseId="short-slow", suite="short", timingBucket="short-expression",
                 totalMs=None, generated=False, truncated=True, error=None, ipcRequestMs=1900.0,
                 hardening={"verdict": "fallback-original", "reason": "truncated", "normalizedOutput": None}),
    ]
    fake_counts = counts(short_extra=1)
    run = make_run(rows, fake_counts)
    latency = SUM.build_latency([(run, rows)], rows)
    over = latency["backends"]["fake"]["directions"]["en-zh"]["overBudget"]
    assert latency["backends"]["fake"]["directions"]["en-zh"]["overBudgetCount"] == 1
    assert over and over[0]["caseId"] == "short-slow" and over[0]["suite"] == "short", over
    gate = verdict_of(SUM.build_quality(run, [(run, rows)], rows, review, latency, fake_counts))
    assert gate["latencyOverBudget"]["count"] == 1 and "short-slow" in gate["latencyOverBudget"]["cases"]


# ── 3. 缺失审阅不能报完成 ──────────────────────────────────────────────

@check("missing-review-cannot-complete")
def test_missing_review_cannot_complete():
    fake_counts = synthetic_expected({
        "risk": {"en-zh": 1}, "holdout": {"en-zh": 1},
        "short": {"en-zh": 1}, "confirm": {"en-zh": 1},
    })
    speed_rows = [
        make_row(caseId="speed-1", suite="speed", timingBucket="short-expression", totalMs=100.0),
        make_row(caseId="speed-2", suite="speed", timingBucket="short-sentence", totalMs=150.0),
    ]

    def base_rows():
        rows = []
        for suite in ("risk", "holdout", "short", "confirm"):
            rows.append(make_row(
                caseId="%s-ok" % suite, suite=suite, timingBucket="short-expression",
                output="你好", hardening={"verdict": "candidate", "reason": "checks-passed", "normalizedOutput": None},
            ))
        return rows

    rows = base_rows() + speed_rows
    run = make_run(rows, fake_counts | {"speed": {"total": 2, "byDirection": {"en-zh": 2}}})
    latency = SUM.build_latency([(run, rows)], rows)

    # (a) no review file at all -> released candidates pending, gate blocked.
    quality = SUM.build_quality(run, [(run, rows)], rows, None, latency, fake_counts)
    gate = verdict_of(quality)
    assert quality["agentSemanticReview"] == "missing"
    assert gate["reviewCoverage"]["complete"] is False and gate["reviewCoverage"]["missingCount"] == 4, gate
    assert gate["verdict"] == "blocked-pending-review", gate

    # (b) review covers 3 of 4 -> still not complete, still blocked.
    review = {"schemaVersion": 2, "cases": {
        "fake:risk-ok": {"status": "pass"}, "fake:holdout-ok": {"status": "pass"},
        "fake:short-ok": {"status": "pass"},
    }}
    quality = SUM.build_quality(run, [(run, rows)], rows, review, latency, fake_counts)
    gate = verdict_of(quality)
    assert gate["reviewCoverage"]["complete"] is False
    assert gate["reviewCoverage"]["missingIds"] == ["confirm-ok"]
    assert gate["verdict"] == "blocked-pending-review", gate

    # (c) full review coverage -> still blocked because the user blind test is not run.
    review["cases"]["fake:confirm-ok"] = {"status": "pass"}
    quality = SUM.build_quality(run, [(run, rows)], rows, review, latency, fake_counts)
    gate = verdict_of(quality)
    assert gate["reviewCoverage"]["complete"] is True
    assert gate["userBlindTest"] == "not-run"
    assert gate["verdict"] == "blocked-pending-review", gate


# ── 4. 已知错误即使通过过滤也不能计为语义合格 ────────────────────────

@check("known-error-not-qualified")
def test_known_error_not_qualified():
    fake_counts = synthetic_expected({
        "risk": {"en-zh": 1}, "holdout": {"en-zh": 1},
        "short": {"en-zh": 1}, "confirm": {"en-zh": 1},
    })
    # Auto-detected: real risk case whose output slipped through the hardening
    # filter but misses the mechanical requireAny (会议 -> 会见).
    rows = [
        make_row(caseId="speed-1", suite="speed", timingBucket="short-expression", totalMs=100.0),
        make_row(caseId="speed-2", suite="speed", timingBucket="short-sentence", totalMs=150.0),
        # `en-sentence` is a real fixed-risk id: its mechanical check forbids 会见.
        make_row(caseId="en-sentence", suite="risk", source="I have a meeting tomorrow.",
                 timingBucket="short-sentence", output="我明天会见。",
                 hardening={"verdict": "candidate", "reason": "checks-passed", "normalizedOutput": None}),
        make_row(caseId="holdout-review-error", suite="holdout", timingBucket="short-expression",
                 output="Banking", hardening={"verdict": "candidate", "reason": "checks-passed", "normalizedOutput": None}),
        make_row(caseId="short-ok", suite="short", timingBucket="short-expression", output="你好",
                 hardening={"verdict": "candidate", "reason": "checks-passed", "normalizedOutput": None}),
        make_row(caseId="confirm-override", suite="confirm", timingBucket="short-expression", output="我明天会见。",
                 hardening={"verdict": "candidate", "reason": "checks-passed", "normalizedOutput": None}),
    ]
    run = make_run(rows, fake_counts | {"speed": {"total": 2, "byDirection": {"en-zh": 2}}})
    latency = SUM.build_latency([(run, rows)], rows)
    review = {"schemaVersion": 2, "cases": {
        "fake:holdout-review-error": {"status": "fail", "category": "meaning-error", "note": "Banking 不是银行的默认候选"},
        "fake:short-ok": {"status": "pass"},
        "fake:confirm-override": {"status": "pass", "note": "人工审阅推翻机械信号：语境下可接受"},
    }}
    quality = SUM.build_quality(run, [(run, rows)], rows, review, latency, fake_counts)
    gate = verdict_of(quality)
    risk_suite = quality["backends"]["fake"]["suites"]["risk"]
    assert risk_suite["errorReleasedIds"] == ["en-sentence"], risk_suite
    assert risk_suite["semanticQualified"] == 0, risk_suite
    holdout_suite = quality["backends"]["fake"]["suites"]["holdout"]
    assert holdout_suite["errorReleasedIds"] == ["holdout-review-error"], holdout_suite
    confirm_suite = quality["backends"]["fake"]["suites"]["confirm"]
    assert confirm_suite["semanticQualified"] == 1, confirm_suite
    assert gate["errorReleased"]["count"] == 2
    assert gate["unhandledRisk"] == ["en-sentence"] and gate["unhandledRiskCount"] == 1
    assert gate["verdict"] == "fail-unhandled-risk", gate


# ── 5. 应保留标签不能冒充真实识别能力 ────────────────────────────────

@check("preserve-labels-not-detection")
def test_preserve_labels_not_detection():
    fake_counts = synthetic_expected({
        "risk": {"en-zh": 1}, "holdout": {"en-zh": 2},
        "short": {"en-zh": 1}, "confirm": {"en-zh": 1},
    })
    review = {"schemaVersion": 2, "cases": {
        "fake:risk-ok": {"status": "pass"}, "fake:holdout-ok": {"status": "pass"},
        "fake:short-ok": {"status": "pass"}, "fake:confirm-ok": {"status": "pass"},
    }}
    rows = [
        make_row(caseId="speed-1", suite="speed", timingBucket="short-expression", totalMs=100.0),
        make_row(caseId="speed-2", suite="speed", timingBucket="short-sentence", totalMs=150.0),
    ]
    for suite in ("risk", "holdout", "short", "confirm"):
        rows.append(make_row(
            caseId="%s-ok" % suite, suite=suite, timingBucket="short-expression",
            output="你好", hardening={"verdict": "candidate", "reason": "checks-passed", "normalizedOutput": None},
        ))
    rows.append(make_row(
        caseId="holdout-typo", suite="holdout", expectedAction="preserve", kind="typo",
        timingBucket="short-expression", source="metting", output="开会",
        hardening={"verdict": "preserve-expected", "reason": "policy-preserve", "normalizedOutput": None},
    ))
    run = make_run(rows, fake_counts | {"speed": {"total": 2, "byDirection": {"en-zh": 2}}})
    latency = SUM.build_latency([(run, rows)], rows)
    quality = SUM.build_quality(run, [(run, rows)], rows, review, latency, fake_counts)
    direction = quality["backends"]["fake"]["directions"]["en-zh"]
    preserve = direction["preservePolicy"]
    assert preserve["cases"] == 1 and preserve["labelConformance"] == 1, preserve
    assert "标签" in preserve["basis"] and "不能证明" in preserve["basis"], preserve
    assert "识别错拼" in preserve["basis"]
    holdout_suite = quality["backends"]["fake"]["suites"]["holdout"]
    assert holdout_suite["preserveCases"] == 1 and holdout_suite["translateCases"] == 1
    # the preserve row must not inflate candidate or semantic counts
    assert holdout_suite["candidateReleased"] == 1
    # latency.json must carry the same caveat
    note = latency["backends"]["fake"]["directions"]["en-zh"]["preservePolicy"]["note"]
    assert "不作为真实识别能力的证据" in note, note


# ── 6. 汇总侧的数据量断言 ─────────────────────────────────────────────

@check("summarizer-dataset-assertion")
def test_summarizer_dataset_assertion():
    fake_counts = synthetic_expected({"risk": {"en-zh": 1}, "holdout": {"en-zh": 1}, "short": {"en-zh": 1}, "confirm": {"en-zh": 1}})
    rows = [
        make_row(caseId="risk-ok", suite="risk", timingBucket="short-expression"),
        make_row(caseId="holdout-ok", suite="holdout", timingBucket="short-expression"),
        # short suite row missing entirely
        make_row(caseId="confirm-ok", suite="confirm", timingBucket="short-expression"),
    ]
    run = make_run(rows, fake_counts)
    latency = SUM.build_latency([(run, rows)], rows)
    try:
        SUM.build_quality(run, [(run, rows)], rows, None, latency, fake_counts)
    except SystemExit as error:
        assert "short en-zh" in str(error), error
    else:
        raise AssertionError("missing short-suite rows did not fail the summarizer")


def main():
    for name, fn in checks_run:
        fn()
        print("ok: %s" % name)
    print("%d 项断言全部通过" % len(checks_run))
    return 0


if __name__ == "__main__":
    sys.exit(main())
