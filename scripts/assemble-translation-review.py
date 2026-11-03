#!/usr/bin/env python3
"""Assemble the round-2 semantic review file (agent review, not user blind test).

Merges:
  - round-1 fixed-risk-set judgements (probes/results/translation-backends/semantic-review.json)
  - holdout-set judgements produced by the holdout reviewers
  - short-text + confirm-set judgements produced in this round
into one schemaVersion-2 file with the frozen scoring rules, keyed
"backend:caseId". Every released translate case must have an entry; the
summarizer treats any missing entry as pending review, never as complete.
"""
import argparse
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
ROUND1_REVIEW = ROOT / "probes/results/translation-backends/semantic-review.json"
SCORING_RULES = {
    "version": 1,
    "frozenAt": "2026-11-03",
    "source": "validation/translation-confirm-set.json scoringRules + validation/translation-short-expressions.json referenceNote",
    "categories": ["meaning-error", "omission", "addition", "fragment", "unnatural"],
    "rules": [
        "允许通行同义表达与自然措辞，不要求逐字一致；参考译文不是唯一合法答案。",
        "意义错误（改变实体、动作、主体关系或词义）、遗漏（关键实体/时间/数字/否定/条件）、增义（加入原文没有的内容）、残句（截断、复读、尾部残片、不成句）、明显不自然（合格母语者不会这样表达）记 fail 并标注类别。",
        "孤立多义词允许最常见默认义项；孤立词输出常见译法即 pass。",
        "人名地名音译允许通行变体；品牌与代码标识必须原样保留。",
        "时间：数字与相对关系必须保留；不强制源文未说明的限定（『九点到五点』不要求 a.m./p.m.）。",
        "标点（句号/叹号/全角半角）、大小写、繁简（已归一）差异不记 fail。",
        "安全回退（加固层拦截）不是语义合格；『提供了正确译文』与『安全回退成功』分开统计。",
        "本审阅只用于评测评分，不作为运行时安全判定输入。",
    ],
}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--short-confirm-small100", type=Path, required=True)
    parser.add_argument("--short-confirm-quickmt", type=Path, required=True)
    parser.add_argument("--holdout-small100", type=Path, required=True)
    parser.add_argument("--holdout-quickmt", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()

    risk = json.loads(ROUND1_REVIEW.read_text())
    cases = {}
    # Round-1 risk entries carry over verbatim (same fixed risk set, same outputs).
    for key, entry in risk["cases"].items():
        cases[key] = {"status": entry["status"], "note": entry.get("note", "")}
        if entry.get("category"):
            cases[key]["category"] = entry["category"]
    for path, backend, suite in [
        (args.holdout_small100, "small100", "holdout"),
        (args.holdout_quickmt, "quickmt", "holdout"),
        (args.short_confirm_small100, "small100", "short+confirm"),
        (args.short_confirm_quickmt, "quickmt", "short+confirm"),
    ]:
        for entry in json.loads(path.read_text()):
            key = "%s:%s" % (backend, entry["caseId"])
            record = {"status": entry["status"]}
            if entry.get("category"):
                record["category"] = entry["category"]
            if entry.get("note"):
                record["note"] = entry["note"]
            record["suite"] = suite if suite != "short+confirm" else entry.get("suite", "short")
            record["direction"] = entry.get("direction")
            cases[key] = record
    out = {
        "schemaVersion": 2,
        "reviewedAt": "2026-11-03",
        "reviewer": "agent semantic review round 2 (risk entries carried from round 1; not a user blind test)",
        "method": "逐条对照源文、参考译文、审阅提示与放行候选输出；按冻结评分规则判定 pass/fail。fail 附五类之一（meaning-error/omission/addition/fragment/unnatural）。每个进入候选的应译用例都有对应记录。",
        "scoringRules": SCORING_RULES,
        "cases": cases,
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(out, ensure_ascii=False, indent=1) + "\n")
    from collections import Counter
    stats = Counter((key.split(":")[0], v["status"]) for key, v in cases.items())
    print(json.dumps({"entries": len(cases), "byBackendStatus": {"%s:%s" % k: v for k, v in stats.items()}}, ensure_ascii=False, indent=1))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
