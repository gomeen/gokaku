#!/usr/bin/env python3
"""Build the anonymized blind-comparison material for the confirm set.

Reads requests.jsonl rows of the `confirm` suite and writes:
  blind-comparison.json  user-reviewable items: source + two outputs labeled A/B
  blind-comparison.md    the same material as a readable table
  blind-comparison.key.json  the A/B -> backend mapping (opening it unblinds)

Model names never appear in the reviewable files. Which backend sits on which
side is randomized per case with a fixed seed derived from the confirm-set
file hash, so the assignment is reproducible but not guessable from output.
For each case the modal output across rounds is shown; differing variants are
counted in the metadata and noted on the item.
"""
import argparse
import hashlib
import json
import random
import re
from collections import Counter
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent


def read_jsonl(path):
    rows = []
    with path.open() as handle:
        for line in handle:
            line = line.strip()
            if line:
                rows.append(json.loads(line))
    return rows


def modal_output(rows):
    outputs = [row.get("output") or "" for row in rows if row.get("error") is None]
    if not outputs:
        return None, 0
    counts = Counter(outputs)
    output, count = counts.most_common(1)[0]
    return output, len(counts)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--run-dir", type=Path, required=True, help="run dir containing confirm-suite rows")
    parser.add_argument("--confirm", type=Path, default=ROOT / "validation/translation-confirm-set.json")
    parser.add_argument("--output-dir", type=Path, help="default: <run-dir>")
    args = parser.parse_args()
    run_dir = args.run_dir.resolve()
    output_dir = (args.output_dir or run_dir).resolve()

    confirm = json.loads(args.confirm.read_text())
    cases_by_id = {case["id"]: case for case in confirm["cases"]}
    confirm_hash = hashlib.sha256(args.confirm.read_bytes()).hexdigest()

    rows = [row for row in read_jsonl(run_dir / "requests.jsonl") if row.get("suite") == "confirm"]
    if not rows:
        raise SystemExit("no confirm-suite rows in %s" % (run_dir / "requests.jsonl"))
    backends = sorted({row["backend"] for row in rows})
    if len(backends) != 2:
        raise SystemExit("expected exactly 2 backends, got %s" % backends)

    by_case = {}
    for row in rows:
        by_case.setdefault((row["direction"], row["caseId"]), []).append(row)

    items = []
    assignment = {}  # caseId -> which backend sits on side A/B
    for (direction, case_id), case_rows in sorted(by_case.items()):
        case = cases_by_id[case_id]
        per_backend = {}
        for backend in backends:
            output, variants = modal_output([row for row in case_rows if row["backend"] == backend])
            per_backend[backend] = (output, variants)
        if per_backend[backends[0]][0] is None or per_backend[backends[1]][0] is None:
            raise SystemExit("case %s is missing one backend output" % case_id)
        seed = int(hashlib.sha256(("%s|%s|%s" % (confirm_hash[:16], direction, case_id)).encode()).hexdigest()[:8], 16)
        first, second = backends if seed % 2 == 0 else (backends[1], backends[0])
        assignment[case_id] = {"A": first, "B": second}
        items.append({
            "id": case_id,
            "direction": direction,
            "kind": case.get("kind"),
            "source": case["source"],
            "A": per_backend[first][0],
            "B": per_backend[second][0],
            "variants": {
                "A": per_backend[first][1],
                "B": per_backend[second][1],
            },
            "note": "variants>1 表示五轮输出不完全一致",
        })

    by_direction = {}
    for item in items:
        by_direction.setdefault(item["direction"], []).append(item)
    # Randomize item order per direction with a seed fixed by the dataset hash.
    for direction, direction_items in by_direction.items():
        rng = random.Random(int(hashlib.sha256((confirm_hash[:16] + "|" + direction).encode()).hexdigest()[:8], 16))
        rng.shuffle(direction_items)

    reviewable = {
        "schemaVersion": 1,
        "purpose": "用户盲测材料：模型名称隐藏。请对每条选出更合适的译文（或标注两者都不合格）；语义规则与 validation/translation-confirm-set.json 的 scoringRules 一致。",
        "confirmSetSha256": confirm_hash,
        "labelNote": "A/B 与后端的对应关系只存在于 blind-comparison.key.json；审阅完成前不要打开。",
        "directions": {
            direction: [
                {key: item[key] for key in ("id", "kind", "source", "A", "B") if key in item}
                | {"variants": item["variants"]}
                for item in direction_items
            ]
            for direction, direction_items in sorted(by_direction.items())
        },
    }
    key = {
        "schemaVersion": 1,
        "warning": "打开本文件即解除盲测。请在完成审阅后再看。",
        "confirmSetSha256": confirm_hash,
        "assignment": assignment,
    }
    lines = [
        "# 确认集盲测比较材料",
        "",
        "模型名称已隐藏（A/B）。每条请选出更合适的译文，或标注两者都不合格；",
        "允许同义表达；评分规则见 `validation/translation-confirm-set.json`。",
        "`variants` 字段大于 1 表示该侧五轮输出不完全一致。",
        "",
    ]
    for direction, direction_items in sorted(reviewable["directions"].items()):
        lines.append("## 方向 %s" % direction)
        lines.append("")
        lines.append("| # | 用例 | 源文 | A | B | 变体 |")
        lines.append("| ---: | --- | --- | --- | --- | --- |")
        for index, item in enumerate(direction_items, 1):
            lines.append(
                "| %d | `%s` | %s | %s | %s | A:%d B:%d |"
                % (index, item["id"], item["source"], item["A"], item["B"],
                   item["variants"]["A"], item["variants"]["B"])
            )
        lines.append("")
    output_dir.mkdir(parents=True, exist_ok=True)
    (output_dir / "blind-comparison.json").write_text(json.dumps(reviewable, ensure_ascii=False, indent=1) + "\n")
    (output_dir / "blind-comparison.md").write_text("\n".join(lines) + "\n")
    (output_dir / "blind-comparison.key.json").write_text(json.dumps(key, ensure_ascii=False, indent=1) + "\n")
    print(json.dumps({
        "items": len(items),
        "directions": {direction: len(v) for direction, v in sorted(by_direction.items())},
        "outputDir": str(output_dir),
    }, ensure_ascii=False, indent=1))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
