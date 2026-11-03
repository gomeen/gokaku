#!/usr/bin/env python3
"""Unified zh/en translation backend benchmark (model + helper process + hardening).

Design boundary (docs/translation-benchmark-plan.md):
  model layer      tokenizer + CTranslate2 encode/generate/decode inside one worker
  helper layer     JSON-lines stdio request/response, measured in the parent
  hardening layer  production safety rules from GogakuCore applied to each output

Formal timing needs at least five interleaved rounds. Raw request rows are kept
as JSONL; summarisation is a separate step so reports can be regenerated.
"""
import argparse
import datetime
import hashlib
import json
import os
import queue
import random
import re
import shutil
import subprocess
import sys
import threading
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
PROBES = ROOT / "probes"
DEFAULT_SMALL100_ROOT = Path.home() / "Library/Caches/Gogaku/models/small100-gate"
DEFAULT_QUICKMT_ROOT = Path.home() / "Library/Caches/Gogaku/models/quickmt-speed"
DEFAULT_PYTHON = Path.home() / "Library/Caches/Gogaku/models/small100-gate/venv-ct2/bin/python"
DYLIB = ROOT / ".build/core/libgogaku_core.dylib"
RISK_PATH = PROBES / "translation-cases.json"
HOLDOUT_PATH = ROOT / "validation/translation-holdout.json"
SHORT_PATH = ROOT / "validation/translation-short-expressions.json"
CONFIRM_PATH = ROOT / "validation/translation-confirm-set.json"
LANGUAGE_PATH = PROBES / "translation-language-probes.json"
CHECKS_PATH = PROBES / "translation-risk-checks.json"

DIRECTION_ALIASES = {"enToZh": "en-zh", "zhToEn": "zh-en"}
BACKENDS = ("small100", "quickmt")
HARD_BRANDS = {"Gogaku"}

# Suites are explicit; `all` must always contain the frozen 88-item short-text
# set (2026-11-03 decision: the first `all` run silently missed it).
SUITES = ("risk", "holdout", "short", "speed", "language", "confirm")
ALL_SUITES = ("risk", "holdout", "short", "speed")
# Frozen dataset sizes. The loader fails loudly on any mismatch so a silently
# missing or truncated dataset can never pass as a completed evaluation.
EXPECTED_COUNTS = {
    "risk": {"total": 32},
    "holdout": {"total": 200},
    "short": {"total": 88, "en-zh": 44, "zh-en": 44},
    "speed": {"total": 8},
    "language": {"total": 24},
    "confirm": {"total": 100, "en-zh": 50, "zh-en": 50},
}

# Freeze the model identities that were verified against the local artifacts.
# The runner re-hashes every file; these values are the expected upstream pins.
MODEL_PINS = {
    "small100": {
        "repository": "alirezamsh/small100",
        "revision": "8ab680e26a596d2e3d2d2d17ae0f68df1037328c",
        "license": "MIT (model card); tokenization_small100.py Apache-2.0",
        "root": DEFAULT_SMALL100_ROOT,
        "artifact": "ct2-int8",
    },
    "quickmt-en-zh": {
        "repository": "quickmt/quickmt-en-zh",
        "revision": "f48b69e53866b717607b59f94350e9aae3ed021c",
        "license": "CC-BY-4.0 (model); quickmt tooling Apache-2.0",
        "root": DEFAULT_QUICKMT_ROOT / "quickmt-en-zh",
        "artifact": "native CT2 int8",
    },
    "quickmt-zh-en": {
        "repository": "quickmt/quickmt-zh-en",
        "revision": "c27cc8024e01a047733a1e34796e2ab19d74b237",
        "license": "CC-BY-4.0 (model); quickmt tooling Apache-2.0",
        "root": DEFAULT_QUICKMT_ROOT / "quickmt-zh-en",
        "artifact": "native CT2 int8",
    },
}

SPEED_CASES = [
    {"id": "speed-en-expression-1", "direction": "en-zh", "kind": "phrase", "timingBucket": "short-expression", "source": "Good morning."},
    {"id": "speed-en-expression-2", "direction": "en-zh", "kind": "word", "timingBucket": "short-expression", "source": "tomorrow"},
    {"id": "speed-en-sentence-1", "direction": "en-zh", "kind": "sentence", "timingBucket": "short-sentence", "source": "I have a meeting tomorrow."},
    {"id": "speed-en-sentence-2", "direction": "en-zh", "kind": "sentence", "timingBucket": "short-sentence", "source": "The meeting is at 3 p.m. tomorrow."},
    {"id": "speed-zh-expression-1", "direction": "zh-en", "kind": "phrase", "timingBucket": "short-expression", "source": "早上好。"},
    {"id": "speed-zh-expression-2", "direction": "zh-en", "kind": "word", "timingBucket": "short-expression", "source": "明天"},
    {"id": "speed-zh-sentence-1", "direction": "zh-en", "kind": "sentence", "timingBucket": "short-sentence", "source": "我明天有个会。"},
    {"id": "speed-zh-sentence-2", "direction": "zh-en", "kind": "sentence", "timingBucket": "short-sentence", "source": "明天下午三点开会。"},
]


def normalize_direction(value):
    return DIRECTION_ALIASES.get(value, value)


def sha256_text(text):
    return hashlib.sha256(text.encode("utf-8")).hexdigest()


def atomic_write(path, value):
    temporary = path.with_suffix(path.suffix + ".writing")
    temporary.write_text(json.dumps(value, ensure_ascii=False, indent=1) + "\n")
    temporary.replace(path)


def now_utc():
    return datetime.datetime.now(datetime.timezone.utc).isoformat()


def system_state():
    cpu = ""
    try:
        cpu = subprocess.check_output(
            "ps -A -o pid,pcpu,comm | sort -k2 -rn | head -8",
            shell=True,
            text=True,
            stderr=subprocess.DEVNULL,
        ).strip()
    except Exception:
        pass
    return {"uptime": subprocess.check_output(["uptime"], text=True).strip(), "loadAverage": os.getloadavg(), "topCpu": cpu}


def kind_class(kind):
    if kind in ("word", "typo", "unknown"):
        return "word"
    if kind == "phrase":
        return "phrase"
    return "sentence"


def input_width(source):
    """Rough input length: CJK chars count one by one, latin text by words."""
    source = source or ""
    cjk = sum(1 for ch in source if "\u4e00" <= ch <= "\u9fff")
    words = len([word for word in re.split(r"\s+", source) if word])
    return cjk + words


def timing_bucket(case):
    if case.get("timingBucket"):
        return case["timingBucket"]
    # 2026-11-03 decision: group by input length first, so short time
    # expressions, names and brands are not lumped into the sentence bucket
    # just because of their `kind` label.
    if kind_class(case.get("kind")) == "word":
        return "short-expression"
    return "short-expression" if input_width(case.get("source")) <= 8 else "short-sentence"


def assert_loaded_counts(by_suite):
    """Fail loudly if a frozen dataset does not match its expected size."""
    problems = []
    for suite, expected in EXPECTED_COUNTS.items():
        if not by_suite.get(suite):
            continue
        cases = by_suite[suite]
        if len(cases) != expected["total"]:
            problems.append("%s: loaded %d cases, expected %d" % (suite, len(cases), expected["total"]))
        by_direction = {}
        for case in cases:
            by_direction[case["direction"]] = by_direction.get(case["direction"], 0) + 1
        for direction, count in expected.items():
            if direction == "total":
                continue
            if by_direction.get(direction) != count:
                problems.append(
                    "%s %s: loaded %d cases, expected %d"
                    % (suite, direction, by_direction.get(direction, 0), count)
                )
    ids = {}
    for suite, cases in by_suite.items():
        for case in cases:
            ids.setdefault(case["id"], []).append(suite)
    for case_id, suites in sorted(ids.items()):
        if len(suites) > 1:
            problems.append("case id %r appears in multiple suites: %s" % (case_id, suites))
    if problems:
        raise SystemExit("dataset assertion failed: " + "; ".join(problems))


def expected_action(case):
    if case.get("expectedAction"):
        return case["expectedAction"]
    if case.get("kind") in ("typo", "unknown"):
        return "preserve"
    return "translate"


def resolve_suites(spec):
    """`all` = risk+holdout+short+speed; comma-separated names pick suites."""
    if spec == "all-language":
        return list(ALL_SUITES) + ["language"]
    if spec == "all":
        return list(ALL_SUITES)
    names = [name.strip() for name in spec.split(",") if name.strip()]
    unknown = [name for name in names if name not in SUITES]
    if unknown:
        raise SystemExit("unknown suites: %s (choose from %s, all, all-language)" % (unknown, SUITES))
    if not names:
        raise SystemExit("no suites selected")
    return list(dict.fromkeys(names))


def load_cases(suite_spec):
    suites = resolve_suites(suite_spec)
    selected = []
    if "risk" in suites:
        selected.extend((case, "risk") for case in json.loads(RISK_PATH.read_text()))
    if "holdout" in suites:
        selected.extend((case, "holdout") for case in json.loads(HOLDOUT_PATH.read_text())["cases"])
    if "short" in suites:
        selected.extend((case, "short") for case in json.loads(SHORT_PATH.read_text())["cases"])
    if "speed" in suites:
        selected.extend((case, "speed") for case in SPEED_CASES)
    if "language" in suites:
        selected.extend((case, "language") for case in json.loads(LANGUAGE_PATH.read_text())["cases"])
    if "confirm" in suites:
        confirm_data = json.loads(CONFIRM_PATH.read_text())
        if not confirm_data.get("scoringRules", {}).get("frozenBeforeRun"):
            raise SystemExit("confirm set scoring rules are not frozen; refusing to run")
        selected.extend((case, "confirm") for case in confirm_data["cases"])
    by_suite = {}
    for case, source_suite in selected:
        normalized = dict(case)
        normalized["direction"] = normalize_direction(case.get("direction"))
        normalized["suite"] = source_suite
        normalized["expectedAction"] = expected_action(case)
        normalized["kindClass"] = kind_class(case.get("kind"))
        normalized["timingBucket"] = timing_bucket(case)
        by_suite.setdefault(source_suite, []).append(normalized)
    assert_loaded_counts({suite: by_suite.get(suite, []) for suite in suites})
    cases = [case for suite in suites for case in by_suite.get(suite, [])]
    return cases, by_suite


def load_risk_checks():
    return json.loads(CHECKS_PATH.read_text())["cases"]


def file_sha256(path):
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def dataset_hashes():
    paths = [RISK_PATH, HOLDOUT_PATH, SHORT_PATH, CONFIRM_PATH, LANGUAGE_PATH, CHECKS_PATH]
    hashes = {}
    for path in paths:
        if path.is_file():
            hashes[path.name] = {
                "sha256": file_sha256(path),
                "bytes": path.stat().st_size,
            }
    return hashes


class Worker:
    def __init__(self, name, spec, python, log_path, threads, compute_type, beam, max_decoding_length):
        self.name = name
        self.spec = spec
        self.log = log_path.open("w")
        command = [
            str(python),
            "-u",
            str(PROBES / "translation-backend-worker.py"),
            "--backend",
            spec["backend"],
            "--root",
            str(spec["root"]),
            "--direction",
            spec["direction"],
            "--threads",
            str(threads),
            "--compute-type",
            compute_type,
            "--beam",
            str(beam),
            "--max-decoding-length",
            str(max_decoding_length),
        ]
        start = time.perf_counter()
        self.process = subprocess.Popen(
            command,
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=self.log,
            text=True,
            bufsize=1,
            start_new_session=True,
        )
        self.messages = queue.Queue()
        self.reader = threading.Thread(target=self._read_output, daemon=True)
        self.reader.start()
        self.ready = self.read(timeout=240)
        if self.ready.get("event") != "ready":
            self.close()
            raise RuntimeError("%s failed to load: %s" % (name, self.ready))
        self.ready["parentReadyMs"] = (time.perf_counter() - start) * 1000.0
        self.dead = False
        self.requests = 0

    def _read_output(self):
        for line in self.process.stdout:
            self.messages.put(line)
        self.messages.put(None)

    def read(self, timeout):
        try:
            line = self.messages.get(timeout=timeout)
        except queue.Empty:
            raise TimeoutError("%s produced no protocol message within %ss" % (self.name, timeout))
        if line is None:
            code = self.process.poll()
            raise RuntimeError("%s exited with status %s" % (self.name, code))
        return json.loads(line)

    def request(self, cases, phase, timeout=30):
        payload = json.dumps({"cases": cases, "phase": phase}, ensure_ascii=False) + "\n"
        start = time.perf_counter_ns()
        self.process.stdin.write(payload)
        self.process.stdin.flush()
        rows = []
        while True:
            message = self.read(timeout)
            if message.get("event") == "request_done":
                break
            if message.get("event") != "result":
                raise RuntimeError("%s unexpected event: %s" % (self.name, message))
            rows.append(message)
        self.requests += 1
        return rows, (time.perf_counter_ns() - start) / 1e6

    def stop(self):
        stopped_peak = self.ready.get("peakRssBytes")
        if self.process.poll() is None:
            try:
                self.process.stdin.write('{"event":"stop"}\n')
                self.process.stdin.flush()
                message = self.read(timeout=20)
                stopped_peak = message.get("peakRssBytes", stopped_peak)
            except Exception:
                pass
            try:
                self.process.wait(timeout=20)
            except Exception:
                pass
        self.close()
        return stopped_peak

    def close(self):
        if self.process.poll() is None:
            try:
                self.process.kill()
            except Exception:
                pass
            try:
                self.process.wait(timeout=10)
            except Exception:
                pass
        self.log.close()


class Hardening:
    def __init__(self, path):
        import ctypes

        if not path.is_file():
            raise RuntimeError("hardening dylib is missing: %s (build .build/core first)" % path)
        self.ctypes = ctypes
        self.lib = ctypes.CDLL(str(path))
        self.lib.gc_translate_repeat_classify.argtypes = [ctypes.c_char_p, ctypes.c_size_t]
        self.lib.gc_translate_repeat_classify.restype = ctypes.c_int32
        self.lib.gc_translate_t2s.argtypes = [ctypes.c_char_p, ctypes.c_size_t, ctypes.c_char_p, ctypes.c_size_t]
        self.lib.gc_translate_t2s.restype = ctypes.c_size_t
        self.lib.gc_translate_has_traditional.argtypes = [ctypes.c_char_p, ctypes.c_size_t]
        self.lib.gc_translate_has_traditional.restype = ctypes.c_int32
        self.lib.gc_translate_time_check.argtypes = [ctypes.c_char_p, ctypes.c_size_t, ctypes.c_char_p, ctypes.c_size_t]
        self.lib.gc_translate_time_check.restype = ctypes.c_int32
        self.lib.gc_translate_script_check.argtypes = [ctypes.c_char_p, ctypes.c_size_t, ctypes.c_char]
        self.lib.gc_translate_script_check.restype = ctypes.c_int32
        self.lib.gc_translate_length_check.argtypes = [ctypes.c_char_p, ctypes.c_size_t, ctypes.c_char_p, ctypes.c_size_t]
        self.lib.gc_translate_length_check.restype = ctypes.c_int32

        class TextRange(ctypes.Structure):
            _fields_ = [("begin", ctypes.c_size_t), ("end", ctypes.c_size_t)]

        self.TextRange = TextRange
        self.lib.gc_translate_protection_scan.argtypes = [
            ctypes.c_char_p,
            ctypes.c_size_t,
            ctypes.POINTER(TextRange),
            ctypes.c_size_t,
        ]
        self.lib.gc_translate_protection_scan.restype = ctypes.c_size_t

    def _t2s(self, text):
        raw = text.encode("utf-8")
        needed = self.lib.gc_translate_t2s(raw, len(raw), None, 0)
        buffer = self.ctypes.create_string_buffer(needed)
        self.lib.gc_translate_t2s(raw, len(raw), buffer, needed)
        return buffer.value.decode("utf-8")

    def _protected(self, text):
        raw = text.encode("utf-8")
        total = self.lib.gc_translate_protection_scan(raw, len(raw), None, 0)
        if total == 0:
            return []
        ranges = (self.TextRange * total)()
        self.lib.gc_translate_protection_scan(raw, len(raw), ranges, total)
        return [raw[ranges[i].begin:ranges[i].end].decode("utf-8") for i in range(total)]

    @staticmethod
    def _is_hard(token):
        if "://" in token or token.startswith("www."):
            return True
        if re.match(r"^v?\d+(\.\d+)+$", token):
            return True
        if token in HARD_BRANDS:
            return True
        if token.isupper() and len(token) >= 2:
            return True
        if any(ch.isupper() for ch in token[1:]):
            return True
        return False

    def apply(self, source, output, direction, expected, truncated=False, error=None):
        start = time.perf_counter_ns()
        raw = (output or "").encode("utf-8")
        result = {
            "verdict": "candidate",
            "reason": None,
            "repeat": None,
            "time": None,
            "length": None,
            "script": None,
            "traditional": None,
            "normalizedOutput": None,
            "protectedTokens": [],
            "hardMissing": [],
            "softMissing": [],
        }
        if error:
            result.update({"verdict": "error", "reason": "worker-error"})
            result["ms"] = (time.perf_counter_ns() - start) / 1e6
            return result
        if direction not in ("en-zh", "zh-en"):
            result.update({"verdict": "unscored", "reason": "script-check-not-defined"})
            result["ms"] = (time.perf_counter_ns() - start) / 1e6
            return result
        if not raw.decode("utf-8", "replace").strip():
            result.update({"verdict": "empty", "reason": "empty-output"})
            result["ms"] = (time.perf_counter_ns() - start) / 1e6
            return result
        result["repeat"] = int(self.lib.gc_translate_repeat_classify(raw, len(raw)))
        result["time"] = int(
            self.lib.gc_translate_time_check(
                source.encode("utf-8"), len(source.encode("utf-8")), raw, len(raw)
            )
        )
        result["length"] = int(
            self.lib.gc_translate_length_check(
                source.encode("utf-8"), len(source.encode("utf-8")), raw, len(raw)
            )
        )
        result["traditional"] = int(self.lib.gc_translate_has_traditional(raw, len(raw)))
        expected_script = b"Z" if direction == "en-zh" else b"E"
        result["script"] = int(self.lib.gc_translate_script_check(raw, len(raw), expected_script))
        tokens = self._protected(source)
        result["protectedTokens"] = tokens
        lowered = (output or "").lower()
        for token in tokens:
            if token.lower() not in lowered:
                if self._is_hard(token):
                    result["hardMissing"].append(token)
                else:
                    result["softMissing"].append(token)

        if expected == "preserve":
            result.update({"verdict": "preserve-expected", "reason": "policy-preserve"})
        elif truncated:
            result.update({"verdict": "fallback-original", "reason": "truncated"})
        elif result["repeat"] >= 1:
            result.update({"verdict": "fallback-original", "reason": "repeat"})
        elif result["time"] in (1, 2, 3):
            result.update({"verdict": "fallback-original", "reason": "time"})
        elif result["length"] in (1, 2):
            result.update({"verdict": "fallback-original", "reason": "length"})
        elif result["hardMissing"]:
            result.update({"verdict": "fallback-original", "reason": "protection"})
        elif result["script"] != 0:
            if result["traditional"]:
                normalized = self._t2s(output)
                normalized_raw = normalized.encode("utf-8")
                normalized_script = int(
                    self.lib.gc_translate_script_check(normalized_raw, len(normalized_raw), expected_script)
                )
                normalized_repeat = int(
                    self.lib.gc_translate_repeat_classify(normalized_raw, len(normalized_raw))
                )
                result["normalizedOutput"] = normalized
                if normalized_script == 0 and normalized_repeat == 0:
                    result.update({"verdict": "candidate-normalized", "reason": "traditional-normalized"})
                else:
                    result.update({"verdict": "fallback-original", "reason": "script"})
            else:
                result.update({"verdict": "fallback-original", "reason": "script"})
        else:
            result.update({"verdict": "candidate", "reason": "checks-passed"})
        result["ms"] = (time.perf_counter_ns() - start) / 1e6
        return result


def semantic_check(case, output, hardening, checks):
    check = checks.get(case.get("id"))
    if not check or check.get("policy") == "preserve" or case.get("expectedAction") == "preserve":
        return {"status": "not-applicable"}
    text = (hardening.get("normalizedOutput") or output or "").lower()
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


BUDGETS = {"short-expression": 500.0, "short-sentence": 2000.0}


def budget_exceeded_ms(case, row, ipc_ms):
    """How far the user-visible wait exceeded the bucket budget, or None.

    Uses the model-reported total when present (a generation capped at the
    length limit still reports it); otherwise the parent-measured wait of a
    failed request. Preserve-expected rows keep the fact but are excluded from
    budget gating downstream because production would not call the model.
    """
    budget = BUDGETS.get(case["timingBucket"])
    if budget is None:
        return None
    wait_ms = row.get("totalMs")
    if wait_ms is None:
        wait_ms = ipc_ms
    if wait_ms is None:
        return None
    return round(wait_ms - budget, 2) if wait_ms > budget else None


def build_worker_specs(backends, directions, small100_root, quickmt_root):
    specs = {}
    if "small100" in backends:
        specs["small100"] = {
            "backend": "small100",
            "root": small100_root,
            "direction": "both",
            "pin": "small100",
        }
    if "quickmt" in backends:
        for direction in directions:
            name = "quickmt-" + direction
            specs[name] = {
                "backend": "quickmt",
                "root": quickmt_root,
                "direction": direction,
                "pin": name,
            }
    return specs


def build_units(backends, directions):
    units = []
    if "small100" in backends:
        for direction in directions:
            units.append({"id": "small100-" + direction, "worker": "small100", "direction": direction})
    if "quickmt" in backends:
        for direction in directions:
            units.append({"id": "quickmt-" + direction, "worker": "quickmt-" + direction, "direction": direction})
    return units


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--backends", nargs="+", choices=BACKENDS, default=list(BACKENDS))
    parser.add_argument("--directions", default="en-zh,zh-en")
    parser.add_argument(
        "--cases",
        default="all",
        help="suite list: all (= risk+holdout+short+speed), all-language, or comma-separated "
        "names from %s" % (SUITES,),
    )
    parser.add_argument("--rounds", type=int, default=5)
    parser.add_argument("--threads", type=int, default=2)
    parser.add_argument("--compute-type", default="int8")
    parser.add_argument("--beam", type=int, default=1)
    parser.add_argument("--max-decoding-length", type=int, default=256)
    parser.add_argument("--python", type=Path, default=DEFAULT_PYTHON)
    parser.add_argument("--small100-root", type=Path, default=DEFAULT_SMALL100_ROOT)
    parser.add_argument("--quickmt-root", type=Path, default=DEFAULT_QUICKMT_ROOT)
    parser.add_argument("--output-dir", type=Path, default=PROBES / "results/translation-backends")
    parser.add_argument("--dylib", type=Path, default=DYLIB)
    parser.add_argument("--no-hardening", action="store_true")
    parser.add_argument("--allow-short-run", action="store_true")
    parser.add_argument("--force", action="store_true")
    args = parser.parse_args()

    if args.rounds < 5 and not args.allow_short_run:
        parser.error("formal timing requires --rounds >= 5; use --allow-short-run only for smoke runs")
    if not args.python.is_file():
        parser.error("worker python is missing: %s" % args.python)
    directions = [normalize_direction(value) for value in args.directions.split(",") if value]
    if not directions:
        parser.error("no directions selected")
    selected_suites = resolve_suites(args.cases)
    if selected_suites == ["language"]:
        language_directions = sorted({case["direction"] for case in load_cases("language")[0]})
        directions = [direction for direction in directions if direction in language_directions]
        if not directions:
            parser.error("language suite has no requested directions")

    cases, cases_by_suite = load_cases(args.cases)
    cases = [case for case in cases if case["direction"] in directions]
    for suite in selected_suites:
        if not [case for case in cases_by_suite.get(suite, []) if case["direction"] in directions]:
            parser.error("suite %s has no cases for the selected directions" % suite)
    if not cases:
        parser.error("no cases selected")
    checks = load_risk_checks() if not args.no_hardening else {}
    hardening = None if args.no_hardening else Hardening(args.dylib)
    specs = build_worker_specs(args.backends, directions, args.small100_root, args.quickmt_root)
    units = build_units(args.backends, directions)
    cases_by_unit = {}
    for unit in units:
        cases_by_unit[unit["id"]] = [case for case in cases if case["direction"] == unit["direction"]]
        if not cases_by_unit[unit["id"]]:
            parser.error("unit %s has no cases" % unit["id"])

    output_dir = args.output_dir.resolve()
    if output_dir.exists() and any(output_dir.iterdir()):
        if not args.force:
            parser.error("output dir is not empty: %s (use --force)" % output_dir)
        shutil.rmtree(output_dir)
    output_dir.mkdir(parents=True, exist_ok=True)
    requests_path = output_dir / "requests.jsonl"
    run_path = output_dir / "run.json"
    run_id = datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    run = {
        "schemaVersion": 1,
        "runId": run_id,
        "startedAt": now_utc(),
        "parameters": {
            "backends": args.backends,
            "directions": directions,
            "cases": args.cases,
            "rounds": args.rounds,
            "threads": args.threads,
            "computeType": args.compute_type,
            "beam": args.beam,
            "maxDecodingLength": args.max_decoding_length,
            "workerPython": str(args.python),
            "small100Root": str(args.small100_root),
            "quickmtRoot": str(args.quickmt_root),
            "hardeningDylib": None if args.no_hardening else str(args.dylib),
            "languageProbes": "not-run" if args.cases != "language" else "run",
        },
        "environment": {
            "platform": sys.platform,
            "machine": os.uname().machine,
            "python": sys.version,
            "system": system_state(),
        },
        "workers": {},
        "caseCounts": {},
        "timingBucketCounts": {},
        "datasetHashes": dataset_hashes(),
        "rounds": [],
    }
    for suite in selected_suites:
        suite_cases = [case for case in cases_by_suite.get(suite, []) if case["direction"] in directions]
        run["caseCounts"][suite] = {
            "total": len(suite_cases),
            "byDirection": {
                direction: sum(1 for case in suite_cases if case["direction"] == direction)
                for direction in directions
            },
        }
    for case in cases:
        run["timingBucketCounts"][case["timingBucket"]] = run["timingBucketCounts"].get(case["timingBucket"], 0) + 1
    atomic_write(run_path, run)

    workers = {}
    for name, spec in specs.items():
        log_path = output_dir / ("worker-" + name + ".stderr.log")
        print("starting %s (%s)" % (name, spec["root"]), flush=True)
        worker = Worker(
            name,
            spec,
            args.python,
            log_path,
            args.threads,
            args.compute_type,
            args.beam,
            args.max_decoding_length,
        )
        workers[name] = worker
        run["workers"][name] = {
            "spec": {"backend": spec["backend"], "direction": spec["direction"], "root": str(spec["root"])},
            "pin": {key: (str(value) if isinstance(value, Path) else value) for key, value in MODEL_PINS.get(spec["pin"], {}).items()},
            "ready": worker.ready,
            "stderrLog": str(log_path),
        }
    atomic_write(run_path, run)

    # Warm up every unit; warmup rows are evidence but never enter latency.
    warmup_cases = {}
    for unit in units:
        candidate = [case for case in cases_by_unit[unit["id"]] if case["suite"] == "speed"]
        if not candidate:
            candidate = cases_by_unit[unit["id"]]
        warmup_cases[unit["id"]] = candidate[:2]
    warmup_rows = {}
    for unit in units:
        worker = workers[unit["worker"]]
        try:
            rows, ipc_ms = worker.request(warmup_cases[unit["id"]], "warmup")
            warmup_rows[unit["id"]] = {"ipcMs": ipc_ms, "rows": rows}
        except Exception as error:
            warmup_rows[unit["id"]] = {"error": repr(error)}
            worker.dead = True
    run["warmup"] = warmup_rows
    atomic_write(run_path, run)

    sequence = 0
    try:
        with requests_path.open("w") as requests:
            for round_index in range(args.rounds):
                round_started = now_utc()
                round_before = system_state()
                order = list(units)
                random.Random(4107 + round_index).shuffle(order)
                round_rows = 0
                round_errors = 0
                for unit in order:
                    worker = workers[unit["worker"]]
                    unit_cases = list(cases_by_unit[unit["id"]])
                    random.Random(701 + round_index * 31 + len(unit["id"])).shuffle(unit_cases)
                    for case in unit_cases:
                        sequence += 1
                        wait_start = time.perf_counter_ns()
                        if worker.dead:
                            row = {
                                "event": "result",
                                "id": case["id"],
                                "direction": case["direction"],
                                "generated": False,
                                "error": "worker-dead",
                                "errorType": "WorkerDead",
                                "peakRssBytes": None,
                            }
                            ipc_ms = None
                        else:
                            try:
                                rows, ipc_ms = worker.request([case], "measure")
                                row = rows[0] if rows else {
                                    "event": "result",
                                    "id": case["id"],
                                    "direction": case["direction"],
                                    "generated": False,
                                    "error": "missing result",
                                    "errorType": "Protocol",
                                }
                            except Exception as error:
                                # Keep the wall-clock wait of failed requests; the
                                # user waits even when generation fails.
                                ipc_ms = (time.perf_counter_ns() - wait_start) / 1e6
                                row = {
                                    "event": "result",
                                    "id": case["id"],
                                    "direction": case["direction"],
                                    "generated": False,
                                    "error": repr(error),
                                    "errorType": type(error).__name__,
                                }
                                worker.dead = True
                        hard = {"verdict": "unscored", "reason": "hardening-disabled"}
                        if hardening is not None:
                            try:
                                hard = hardening.apply(
                                    case["source"],
                                    row.get("output"),
                                    case["direction"],
                                    case["expectedAction"],
                                    truncated=bool(row.get("truncated")),
                                    error=row.get("error"),
                                )
                            except Exception as error:
                                hard = {"verdict": "error", "reason": "hardening-exception", "error": repr(error)}
                        semantic = semantic_check(case, row.get("output"), hard, checks)
                        record = {
                            "schemaVersion": 1,
                            "runId": run_id,
                            "round": round_index + 1,
                            "sequence": sequence,
                            "backend": unit["worker"].split("-")[0] if unit["worker"].startswith("quickmt") else "small100",
                            "worker": unit["worker"],
                            "caseId": case["id"],
                            "suite": case["suite"],
                            "direction": case["direction"],
                            "kind": case.get("kind"),
                            "kindClass": case["kindClass"],
                            "timingBucket": case["timingBucket"],
                            "expectedAction": case["expectedAction"],
                            "source": case["source"],
                            "sourceSha256": sha256_text(case["source"]),
                            "sourceChars": len(case["source"]),
                            "output": row.get("output"),
                            "generated": bool(row.get("generated")),
                            "truncated": bool(row.get("truncated")),
                            "error": row.get("error"),
                            "errorType": row.get("errorType"),
                            "inputTokens": row.get("inputTokens"),
                            "outputTokens": row.get("outputTokens"),
                            "sourceUnknownTokens": row.get("sourceUnknownTokens"),
                            "score": row.get("score"),
                            "encodeMs": row.get("encodeMs"),
                            "generateMs": row.get("generateMs"),
                            "decodeMs": row.get("decodeMs"),
                            "totalMs": row.get("totalMs"),
                            "cpuMs": row.get("cpuMs"),
                            "peakRssBytes": row.get("peakRssBytes"),
                            "ipcRequestMs": ipc_ms,
                            "ipcOverheadMs": (ipc_ms - row.get("totalMs")) if (ipc_ms is not None and row.get("totalMs") is not None) else None,
                            "budgetMs": BUDGETS.get(case["timingBucket"]),
                            "budgetExceededMs": budget_exceeded_ms(case, row, ipc_ms),
                            "hardening": hard,
                            "semantic": semantic,
                            "modelIdentity": worker.ready.get("identity"),
                        }
                        requests.write(json.dumps(record, ensure_ascii=False) + "\n")
                        requests.flush()
                        round_rows += 1
                        if record["error"] or hard.get("verdict") in ("error", "empty"):
                            round_errors += 1
                run["rounds"].append(
                    {
                        "round": round_index + 1,
                        "startedAt": round_started,
                        "finishedAt": now_utc(),
                        "rows": round_rows,
                        "errors": round_errors,
                        "systemBefore": round_before,
                        "systemAfter": system_state(),
                    }
                )
                atomic_write(run_path, run)
                print("round %d/%d: %d requests, %d errors" % (round_index + 1, args.rounds, round_rows, round_errors), flush=True)
    finally:
        for name, worker in workers.items():
            run["workers"][name]["stoppedPeakRssBytes"] = worker.stop()
        run["finishedAt"] = now_utc()
        run["requestCount"] = sequence
        run["totalRequestsPerWorker"] = {name: worker.requests for name, worker in workers.items()}
        atomic_write(run_path, run)
    print("wrote %s and %s" % (requests_path, run_path), flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
