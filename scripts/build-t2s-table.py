#!/usr/bin/env python3
"""生成翻译加固层用的繁→简单字映射表（内嵌 C++ 表，构建期不依赖 OpenCC）。

数据来源：本机 OpenCC（`opencc -c t2s`，Apache-2.0）。逐字符转换 CJK 统一表意
文字、扩展 A、兼容表意文字与 U+3007，保留「转换后发生变化」的字，按码点排序
输出为 native/GogakuCore/translate/t2s_table.inc。产物入库，两端同一字节；
再生成时用 --check 对比差异，不静默改表。

注意：这是单字级映射（OpenCC TSCharacters），不含词组级（TSPhrases）转换；
「滑鼠→鼠标」类地区词不在覆盖范围，v1 明确接受（见模型解堵调研§四残余风险）。
"""
import argparse
import hashlib
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / "native/GogakuCore/translate/t2s_table.inc"
HEADER = """// 由 scripts/build-t2s-table.py 生成，勿手改；{n} 个条目，生成于 {date}。
// 数据来源：OpenCC {ocver} `t2s` 配置（https://github.com/BYVoid/OpenCC，Apache-2.0）。
// 单字级繁→简映射（不含词组级）；条目按码点升序，二分查找。
"""


def domain():
    for a, b in ((0x3400, 0x4DBF), (0x4E00, 0x9FFF), (0xF900, 0xFAFF)):
        yield from range(a, b + 1)
    yield 0x3007  # 〇


def convert(opencc: str, chars: list[str]) -> str:
    text = "".join(ch + "\n" for ch in chars)
    result = subprocess.run([opencc, "-c", "t2s"], input=text, capture_output=True,
                            text=True, check=True)
    return result.stdout


def build(opencc: str) -> list[tuple[int, int]]:
    chars = [chr(cp) for cp in domain()]
    lines = convert(opencc, chars).splitlines()
    assert len(lines) == len(chars), f"opencc 输出行数不符：{len(lines)} != {len(chars)}"
    pairs = []
    for src, dst in zip(chars, lines):
        if dst and dst != src:
            pairs.append((ord(src), ord(dst[0])))
    pairs.sort()
    return pairs


def render(pairs, ocver: str, date: str) -> str:
    out = [HEADER.format(n=len(pairs), ocver=ocver, date=date)]
    out.append("struct GcT2sEntry { unsigned trad; unsigned simp; };\n")
    out.append("static constexpr GcT2sEntry kT2sTable[] = {\n")
    for i in range(0, len(pairs), 4):
        row = ", ".join(f"{{0x{t:04X},0x{s:04X}}}" for t, s in pairs[i:i + 4])
        out.append("    " + row + ",\n")
    out.append("};\n")
    out.append(
        "static constexpr size_t kT2sTableSize = "
        "sizeof(kT2sTable) / sizeof(kT2sTable[0]);\n")
    return "".join(out)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--opencc", default="/usr/local/bin/opencc")
    parser.add_argument("--ocver", default="1.4.2")
    parser.add_argument("--date", default="2026-11-02")
    parser.add_argument("--check", action="store_true", help="只对比不写文件")
    args = parser.parse_args()

    pairs = build(args.opencc)
    content = render(pairs, args.ocver, args.date)
    digest = hashlib.sha256(content.encode()).hexdigest()[:16]
    print(f"entries={len(pairs)} sha256[:16]={digest}")
    if args.check:
        current = OUT.read_text() if OUT.exists() else ""
        print("identical" if current == content else "DIFFERS from committed table")
        return 0 if current == content else 1
    OUT.parent.mkdir(parents=True, exist_ok=True)
    OUT.write_text(content)
    print(f"wrote {OUT}")


if __name__ == "__main__":
    sys.exit(main())
