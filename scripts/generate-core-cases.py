#!/usr/bin/env python3
"""从 probes 的 120 条中文测试集生成 C++ include 数组（质量回归与基准共用）。

输入：probes/input-engine-cases.json（40 条）＋ probes/input-engine-holdout.json（80 条）。
输出：native/GogakuCore/tests/quality_cases.inc
  kQualityCases[]  — {id, keys, targets[], syllables}，供质量回归与性能基准使用。

这些用例冻结在 probes/*.json 中（created_before_measurement），本脚本只做格式
转换，不修改任何按键或目标词。改 probes 数据后必须重新运行本脚本。

用法：python3 scripts/generate-core-cases.py
"""
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / "native/GogakuCore/tests/quality_cases.inc"


def esc(s: str) -> str:
    return s.replace("\\", "\\\\").replace('"', '\\"')


def main() -> None:
    cases = []
    for name in ("input-engine-cases.json", "input-engine-holdout.json"):
        data = json.loads((ROOT / "probes" / name).read_text())
        cases.extend(data["cases"])
    assert len(cases) == 120, f"预期 120 条，实际 {len(cases)}"

    lines = [
        "// 由 scripts/generate-core-cases.py 从 probes/input-engine-cases.json",
        "// ＋ probes/input-engine-holdout.json 生成；不要手改。",
        "#ifndef GOGAKU_QUALITY_CASES_INC",
        "#define GOGAKU_QUALITY_CASES_INC",
        "",
        "struct QualityCase {",
        "    const char *id;",
        "    const char *keys;        // 小鹤按键序列（ASCII）",
        "    const char *const *targets;",
        "    size_t target_count;",
        "    int syllables;",
        "};",
        "",
    ]
    for i, c in enumerate(cases):
        targets = c["targets"]
        arr = f"static const char *const kTargets{i}[] = {{"
        arr += ", ".join(f'"{esc(t)}"' for t in targets)
        arr += "};"
        lines.append(arr)
    lines.append("")
    lines.append("static const QualityCase kQualityCases[] = {")
    for i, c in enumerate(cases):
        lines.append(
            f'    {{"{esc(c["id"])}", "{esc(c["keys"])}", kTargets{i}, {len(c["targets"])}, {c["syllables"]}}},'
        )
    lines.append("};")
    lines.append("")
    lines.append(f"static const size_t kQualityCaseCount = {len(cases)};")
    lines.append("")
    lines.append("#endif  // GOGAKU_QUALITY_CASES_INC")
    lines.append("")
    OUT.write_text("\n".join(lines))
    print(f"{OUT}（{len(cases)} 条）")


if __name__ == "__main__":
    main()
