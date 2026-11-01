"""Summarize actual translation outputs; generation success is not quality."""
import argparse
import hashlib
import json
from pathlib import Path
import statistics


def read(path):
    return json.loads(path.read_text())


def summarize(directory):
    report = read(directory / "measurements.json")
    if len(report["passes"]) != len(report["parameters"]["configs"]) * report["parameters"]["rounds"]:
        raise RuntimeError("Measurement rounds are incomplete")
    summary = {"parameters": report["parameters"], "configs": [], "load_average_min": min(run["system_before"]["load_average"][0] for run in report["passes"]), "load_average_max": max(run["system_before"]["load_average"][0] for run in report["passes"])}
    for name in report["parameters"]["configs"]:
        runs = [run for run in report["passes"] if run["config"]["id"] == name]
        rows = [row for run in runs for row in run["rows"] if row.get("generated")]
        round_medians = [statistics.median(row["total_ms"] for row in run["rows"] if row.get("generated")) for run in runs if any(row.get("generated") for row in run["rows"])]
        value = {"config": runs[0]["config"], "rounds": len(runs), "expected_requests": len(runs) * len(report["parameters"]["case_ids"]), "generated_requests": len(rows), "error_requests": sum(run["errors"] for run in runs), "worker_failures": sum(run["worker_failures"] for run in runs), "round_medians_ms": round_medians, "median_of_round_medians_ms": statistics.median(round_medians) if round_medians else None, "round_median_range_ms": [min(round_medians), max(round_medians)] if round_medians else None, "peak_process_rss_bytes": max(row["peak_rss_bytes"] for row in rows) if rows else None, "first_model_load_ms": runs[0].get("ready", {}).get("model_load_ms"), "first_process_ready_ms": runs[0].get("ready", {}).get("parent_ready_ms"), "case_timings": [], "phase_share": {}}
        for phase in ["encode_ms", "generate_ms", "decode_ms"]:
            value["phase_share"][phase] = sum(row[phase] for row in rows) / sum(row["total_ms"] for row in rows) if rows else None
        value["cpu_ms_per_wall_ms"] = sum(row["cpu_ms"] for row in rows) / sum(row["total_ms"] for row in rows) if rows else None
        for case_id in report["parameters"]["case_ids"]:
            samples = [row for row in rows if row["id"] == case_id]
            times = [row["total_ms"] for row in samples]
            value["case_timings"].append({"id": case_id, "count": len(samples), "median_ms": statistics.median(times) if times else None, "range_ms": [min(times), max(times)] if times else None, "outputs": sorted({row["output"] for row in samples})})
        summary["configs"].append(value)
    (directory / "measurement-summary.json").write_text(json.dumps(summary, ensure_ascii=False, indent=2) + "\n")
    quality = [read(directory / name) for name in ["quality-greedy.json", "quality-beam4.json"]]
    cases = read(Path(__file__).with_name("translation-cases.json"))
    lines = ["# 原始译文对照", "", "本表从实际探针输出生成。`generated` 只表示非空且未触及输出上限，不表示质量合格。空、截断及错误也保留。", ""]
    headers = [f"{run['config']['id']} beam={run['config']['beam']}" for report in quality for run in report["passes"]]
    lookup = [{row["id"]: row for row in run["rows"]} for report in quality for run in report["passes"]]
    for case in cases:
        lines.extend([f"## {case['id']}", "", f"原文：{case['source']}", "", f"审阅要点：{case['review']}", "", "| 配置 | 实际输出 | 生成完成 |", "| --- | --- | --- |"])
        for header, outputs in zip(headers, lookup):
            row = outputs[case["id"]]
            output = row.get("output", row.get("error", ""))
            if row.get("truncated"):
                output += " [达到输出上限]"
            output = output.replace("|", "\\|").replace("\n", " ") or "[空输出]"
            lines.append(f"| {header} | {output} | {row['generated']} |")
        lines.append("")
    (directory / "quality-outputs.md").write_text("\n".join(lines) + "\n")
    artifacts = []
    for path in sorted(directory.iterdir()):
        if path.is_file() and path.name != "artifact-hashes.json":
            data = path.read_bytes()
            artifacts.append({"path": path.name, "bytes": len(data), "sha256": hashlib.sha256(data).hexdigest()})
    (directory / "artifact-hashes.json").write_text(json.dumps(artifacts, indent=2) + "\n")
    print(json.dumps({"rounds": report["parameters"]["rounds"], "configs": [{"id": row["config"]["id"], "median_ms": row["median_of_round_medians_ms"], "range_ms": row["round_median_range_ms"], "generated_requests": row["generated_requests"], "errors": row["error_requests"], "peak_rss_MiB": row["peak_process_rss_bytes"] / 1048576 if row["peak_process_rss_bytes"] else None} for row in summary["configs"]]}, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("directory", type=Path)
    args = parser.parse_args()
    summarize(args.directory)
