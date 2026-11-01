"""Verify local translation failures and actual inference without network access."""
import argparse
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import tempfile

BASE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("benchmark_translations", BASE / "benchmark-translations.py")
harness = importlib.util.module_from_spec(spec)
spec.loader.exec_module(harness)


def guarded_run(command, request, timeout=120):
    run = subprocess.run(command, input=json.dumps(request, ensure_ascii=False) + '\n{"event":"stop"}\n', capture_output=True, text=True, timeout=timeout)
    events = [json.loads(line) for line in run.stdout.splitlines()]
    return {"returncode": run.returncode, "events": events, "stderr": run.stderr}


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", type=Path, default=Path("/tmp/gogaku-benchmark/models"))
    parser.add_argument("--python", type=Path, default=Path("/tmp/gogaku-benchmark/venv-ct2/bin/python"))
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    cases = json.loads(harness.CASES_PATH.read_text())
    by_id = {case["id"]: case for case in cases}
    config = harness.CONFIGS["opus-ct2-int8-t1"]
    base = [str(args.python), "-u", str(BASE / "translation-worker.py"), "--config", json.dumps(config)]
    profile = '(version 1)(allow default)(deny network*)'
    sandbox = ["sandbox-exec", "-p", profile]
    check = subprocess.run(sandbox + [str(args.python), "-c", "import socket,sys;\ntry:\n s=socket.socket();s.connect(('1.1.1.1',443))\nexcept PermissionError:\n print('network denied');sys.exit(0)\nsys.exit(1)"], capture_output=True, text=True, timeout=10)
    if check.returncode != 0 or check.stdout.strip() != "network denied":
        raise RuntimeError(f"Network sandbox did not deny the control connection: {check.returncode} {check.stderr}")
    results = {"network_control": {"returncode": check.returncode, "stdout": check.stdout, "stderr": check.stderr}, "checks": []}
    args.output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="gogaku-local-validation-") as temporary:
        root = Path(temporary)
        for name, corrupt in [("missing-direction", False), ("corrupt-direction", True)]:
            trial = root / name
            trial.mkdir()
            (trial / "opus-en-zh").symlink_to(args.root / "opus-en-zh", target_is_directory=True)
            if corrupt:
                source = trial / "opus-zh-en" / "source"
                source.mkdir(parents=True)
                for path in (args.root / "opus-zh-en" / "source").iterdir():
                    if path.is_file():
                        (source / path.name).symlink_to(path)
                destination = trial / "opus-zh-en" / "ct2-int8"
                destination.mkdir()
                original = args.root / "opus-zh-en" / "ct2-int8"
                for path in original.iterdir():
                    if path.name != "model.bin":
                        (destination / path.name).symlink_to(path)
                (destination / "model.bin").write_bytes(b"deliberately invalid model fixture")
            run = guarded_run(sandbox + base + ["--root", str(trial)], {"phase": name, "cases": [by_id["en-word"]]})
            passed = run["returncode"] == 2 and any(event.get("event") == "load_error" for event in run["events"])
            results["checks"].append({"name": name, "passed": passed, **run})
        overlength = {"id": "over-token-limit", "direction": "en-zh", "kind": "failure", "source": "meeting " * 1100}
        empty = {"id": "empty-input", "direction": "en-zh", "kind": "failure", "source": "  "}
        for family in ["opus", "m2m100"]:
            family_config = harness.CONFIGS[f"{family}-ct2-int8-t1"]
            family_base = [str(args.python), "-u", str(BASE / "translation-worker.py"), "--config", json.dumps(family_config), "--root", str(args.root)]
            run = guarded_run(sandbox + family_base, {"phase": "network-denied", "cases": [by_id["en-word"], by_id["zh-sentence"], overlength, empty, by_id["en-negation"]]})
            rows = {event["id"]: event for event in run["events"] if event.get("event") == "result"}
            passed = run["returncode"] == 0 and all(rows.get(name, {}).get("generated") for name in ["en-word", "zh-sentence", "en-negation"]) and all(not rows.get(name, {}).get("generated", True) and rows[name].get("error", "").startswith("ValueError(") for name in ["over-token-limit", "empty-input"])
            results["checks"].append({"name": f"{family}-local-load-inference-and-input-validation", "passed": passed, **run})
    results["passed"] = all(check["passed"] for check in results["checks"])
    args.output.write_text(json.dumps(results, ensure_ascii=False, indent=2) + "\n")
    print(json.dumps({"passed": results["passed"], "checks": [{"name": check["name"], "passed": check["passed"]} for check in results["checks"]]}))
    raise SystemExit(0 if results["passed"] else 1)
