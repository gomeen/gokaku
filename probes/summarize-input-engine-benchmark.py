#!/usr/bin/env python3
"""Verify the input benchmark's event coverage and summarize its evidence."""
import argparse
from collections import Counter
import gzip
import hashlib
import json
from pathlib import Path


def load(path):
    return json.loads(path.read_text())


def digest(path):
    h = hashlib.sha256()
    with path.open("rb") as f:
        for part in iter(lambda: f.read(1024 * 1024), b""):
            h.update(part)
    return h.hexdigest()


def save(path, value):
    path.write_text(json.dumps(value, ensure_ascii=False, indent=2) + "\n")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("root", type=Path)
    args = parser.parse_args()
    root = args.root
    # These are generated outputs. A failed re-verification must not leave a
    # previously successful summary next to changed or incomplete raw events.
    for name in ("summary.json", "artifact-hashes.json", "quality-outputs.md"):
        (root / name).unlink(missing_ok=True)
    statuses = {phase: load(root / phase / "status.json") for phase in ("smoke", "quality", "measure", "offline")}
    if not all(status.get("complete") for status in statuses.values()):
        raise ValueError("One or more phases are incomplete")
    inputs = {phase: load(root / phase / "inputs.json") for phase in statuses}
    case_hashes = {value["cases_sha256"] for value in inputs.values()}
    if len(case_hashes) != 1:
        raise ValueError("Cases changed between phases")
    ids = [c["id"] for c in inputs["measure"]["configs"]]
    if any([c["id"] for c in i["configs"]] != ids for i in inputs.values()):
        raise ValueError("Configurations differ between phases")
    if len({i["runner_sha256"] for i in inputs.values()}) != 1:
        raise ValueError("Runner changed between phases")
    measurement = load(root / "measure" / "measurement-summary.json")
    rounds = measurement["rounds"]
    cases = inputs["measure"]["cases"]
    case_by_id = {c["id"]: c for c in cases}
    expected = {(config_id, round_index, case["id"]): len(case["keys"])
                for config_id in ids for round_index in range(rounds) for case in cases}
    seen = Counter()
    anomalies = Counter()
    event_count = 0
    with gzip.open(root / "measure" / "events.jsonl.gz", "rt", encoding="utf-8") as events:
        for line in events:
            event = json.loads(line)
            key = (event["config"], event["round"], event["case"])
            if key not in expected:
                raise ValueError("Unknown event identity: " + repr(key))
            case = case_by_id[event["case"]]
            expected_step = seen[key]
            if event["step"] != expected_step or event["key"] != case["keys"][expected_step]:
                raise ValueError("Duplicate, missing or reordered key: " + repr(key))
            response = event["response"]
            if not response["ok"] or response["commit"]:
                raise ValueError("Failed key or unexpected commit: " + repr(event))
            if response["raw_input"] is not None and response["raw_input"] != case["keys"][:expected_step + 1]:
                anomalies[event["config"] + ":raw_input_mismatch"] += 1
            if response.get("handled") is False:
                anomalies[event["config"] + ":unhandled_keys"] += 1
            if response["total_ns"] < response["process_ns"] + response["collect_ns"]:
                raise ValueError("Timing omits a stage")
            if response["total_ns"] > event["parent_rtt_ns"]:
                raise ValueError("Worker timing exceeds parent round trip")
            seen[key] += 1
            event_count += 1
    if dict(seen) != expected:
        missing = [(key, seen[key], count) for key, count in expected.items() if seen[key] != count]
        raise ValueError("Incomplete event coverage: " + repr(missing[:10]))
    quality = {}
    markdown = ["# 中文候选原始结果", "", "本表由固定合成输入产生；候选出现与一次选择完整提交分开记录。", ""]
    for config_id in ids:
        value = load(root / "quality" / (config_id + ".json"))
        quality[config_id] = {k: v for k, v in value.items() if k != "cases"}
        if [c["id"] for c in value["cases"]] != [c["id"] for c in cases]:
            raise ValueError("Quality case mismatch: " + config_id)
        for field in ("top1", "top10", "single_selection_complete"):
            if value[field] != sum(c[field] for c in value["cases"]):
                raise ValueError("Quality aggregate mismatch")
        markdown += ["## " + config_id, "", "| 输入与目标 | 首选 | 目标索引（0 起） | 一次选择完整提交 | 前十候选 |",
                     "| --- | --- | --- | --- | --- |"]
        for case in value["cases"]:
            candidates = case["final"]["candidates"]
            def cell(text):
                return str(text).replace("|", "\\|").replace("\n", " ")
            markdown.append("| " + " | ".join(map(cell, [case["keys"] + " → " + "/".join(case["targets"]),
                            candidates[0] if candidates else "（空）", case["target_index"],
                            "是" if case["single_selection_complete"] else "否", " / ".join(candidates)])) + " |")
        markdown.append("")
    (root / "quality-outputs.md").write_text("\n".join(markdown) + "\n")
    summary = {"scope": "Core-only hot generation with product data; synthetic exploratory sample, no UI or host validation",
               "verified_complete": True, "config_ids": ids, "cases_sha256": next(iter(case_hashes)),
               "case_count": len(cases), "rounds": rounds, "total_key_events": event_count,
               "events_per_config": {i: sum(n for (c, _, _), n in seen.items() if c == i) for i in ids},
               "anomalies": dict(anomalies), "quality": quality, "measurement": measurement,
               "network_control": load(root / "offline" / "network-control.json")}
    save(root / "summary.json", summary)
    artifacts = {str(path.relative_to(root)): {"bytes": path.stat().st_size, "sha256": digest(path)}
                 for path in sorted(root.rglob("*")) if path.is_file() and path.name != "artifact-hashes.json"}
    save(root / "artifact-hashes.json", artifacts)
    print(json.dumps({k: summary[k] for k in ("verified_complete", "config_ids", "case_count", "rounds", "total_key_events", "anomalies")}, ensure_ascii=False))
    for config_id in ids:
        print(config_id, json.dumps({"quality": quality[config_id], "core": measurement["configs"][config_id]["core"]}, ensure_ascii=False))


if __name__ == "__main__":
    main()
