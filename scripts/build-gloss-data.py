#!/usr/bin/env python3
"""从 Wiktionary wiktextract（kaikki.org）中文词条提取候选注释表 gloss.tsv。

来源与许可（结论见 docs/research-gloss-data.md）：
- kaikki.org per-language 下载（Chinese 词条 JSONL）；Wiktionary 文本 CC BY-SA 4.0
  ＋GFDL 双许可，提取数据按 CC BY-SA 4.0 分发并署名。
- 产物每行：词 <TAB> 注释（「词性. 释义 · 释义」，每词最多 2 个义项）。

质量规则（2026-10-31 随机样例审阅后引入）：
- 简繁映射：Wiktionary 键多为繁体；带 Simplified-Chinese 标签的 forms 映射为
  简体键（覆盖会议→會議、银行→銀行这类常用词）。
- 噪声义项降级：方言／语域标签（粤语、闽南、文学、幽默、粗俗等）的义项排到
  非标签义项之后；alt-of 义项整条剔除（与正文重复）。
- 每词最多 2 个义项；纯标点键（、。…）不收。

运行本脚本只是生成数据文件；把 gloss.tsv 打入输入法包 EngineData 前，必须先在
docs/third-party.md 登记来源、版本、哈希与署名义务（CC BY-SA 4.0、声明修改、
不添加额外限制），并以空表运行回归确认降级路径。

用法：python3 scripts/build-gloss-data.py kaikki-Chinese.jsonl.gz
"""
import gzip
import hashlib
import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent

POS_ABBREV = {
    "noun": "n.", "verb": "v.", "adj": "adj.", "adv": "adv.", "pron": "pron.",
    "prep": "prep.", "conj": "conj.", "interj": "intj.", "particle": "part.",
    "classifier": "cl.", "num": "num.", "phrase": "phr.", "proverb": "prov.",
    "name": "name", "character": "char.",
}

# 这些标签的义项降级：常用词的首义经常是方言／语域用法，非标签义项优先。
NOISE_SUBSTRINGS = (
    "cantonese", "hokkien", "teochew", "hakka", "mandarin", "jin-", "wu-", "xiang",
    "gan-", "literary", "classical", "internet", "humorous", "vulgar",
    "euphemistic", "figurative", "slang", "dialect", "regional", "hong-kong",
)


def is_noise(tags: list[str]) -> bool:
    lowered = [t.lower() for t in tags]
    return any(any(sub in t for sub in NOISE_SUBSTRINGS) for t in lowered)
SKIP_TAGS = {"alt-of", "obsolete", "archaic"}


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def simplified_key(entry: dict) -> str | None:
    """词条键的简体形式：只接受标签恰为 Simplified-Chinese 的 forms。
    带 alternative 等附加标签的是字级变体或部件分解（如 你好→亻尔女子），
    不是词级简繁映射，误收会吞掉原键。"""
    for form in entry.get("forms", []):
        tags = {t.lower() for t in form.get("tags", [])}
        if tags != {"simplified-chinese"}:
            continue
        value = (form.get("form") or "").strip()
        if not value or value == entry.get("word") or len(value) > 16:
            continue
        # 部件分解会含部首区字符（亻〵等），正常词不会。
        if any("\u2e80" <= c <= "\u2fdf" for c in value):
            continue
        return value
    return None


def senses_of(entry: dict) -> list[tuple[bool, str]]:
    """返回 [(是否噪声标签, 文本)]；alt-of／obsolete／archaic 义项剔除。"""
    pos = POS_ABBREV.get(entry.get("pos"), "")
    out = []
    for sense in entry.get("senses", []):
        tags = [t.lower() for t in sense.get("tags", [])]
        if any(t in SKIP_TAGS for t in tags):
            continue
        noise = is_noise(tags)
        for gloss in sense.get("glosses", []) or sense.get("raw_glosses", []):
            text = " ".join([f"({t})" for t in tags[:1]] + [gloss]).strip()
            if text and presentable(text):
                out.append((noise, f"{pos} {text}".strip()))
    return out


def presentable(text: str) -> bool:
    """允许 ASCII、CJK 统一表意、CJK 标点（、。〔〕「」）与全角形式（（）／：）。
    全角标点出现在 Classifier 标记（如 個／个）里，不能因它丢掉整条义项。"""
    for c in text:
        cp = ord(c)
        if cp < 128:
            continue
        if "\u3400" <= c <= "\u9fff" or "\u3000" <= c <= "\u303f" or "\uff00" <= c <= "\uffef":
            continue
        return False
    return True


def main() -> None:
    if len(sys.argv) != 2:
        print(__doc__)
        sys.exit(2)
    source = Path(sys.argv[1])
    opener = gzip.open if source.suffix == ".gz" else open
    entries: dict[str, list[tuple[bool, str]]] = {}
    with opener(source, "rt", encoding="utf-8", errors="replace") as stream:
        for line in stream:
            try:
                entry = json.loads(line)
            except json.JSONDecodeError:
                continue
            word = entry.get("word", "")
            if not word or not all("\u3400" <= c <= "\u9fff" for c in word):
                continue  # 只收纯汉字键；简体键优先由下方映射保证
            if len(word) > 16:
                continue
            key = simplified_key(entry) or word
            if len(key) > 16:
                continue
            found = senses_of(entry)
            if not found:
                continue
            bucket = entries.setdefault(key, [])
            for item in found:
                if item not in bucket:
                    bucket.append(item)
    out = ROOT / "resources" / "gloss.tsv"
    out.parent.mkdir(parents=True, exist_ok=True)
    lines = ["# gloss.tsv — 词性＋译文注释（Wiktionary/wiktextract，CC BY-SA 4.0）",
             f"# 来源：kaikki.org Chinese 提取；文件 {source.name} sha256={sha256(source)}",
             "# 义务：署名 Wiktionary 贡献者、声明修改、衍生数据按 CC BY-SA 4.0 分发、不添加额外限制"]
    for key in sorted(entries):
        bucket = sorted(entries[key], key=lambda item: item[0])  # 非噪声标签义项优先（稳定排序）
        seen: list[str] = []
        for _, text in bucket:
            if text not in seen:
                seen.append(text)
            if len(seen) >= 2:
                break
        lines.append(f"{key}\t{' · '.join(seen)}")
    out.write_text("\n".join(lines) + "\n", encoding="utf-8")
    manifest = {
        "description": "候选窗「词性＋译文」注释（Wiktionary/wiktextract 中文词条，英文释义）",
        "license": {
            "wiktionary": "CC BY-SA 4.0（双许可取 CC 一支）；署名 Wiktionary contributors，声明修改，逐词条原文 URI",
            "wiktextract": "MIT（提取工具，不覆盖输出数据许可）",
        },
        "sources": {
            "kaikki": {"file": source.name, "bytes": source.stat().st_size, "sha256": sha256(source),
                       "url": "https://kaikki.org/dictionary/Chinese/"},
        },
        "entry_count": len(entries),
        "output_sha256": sha256(out),
    }
    (ROOT / "resources" / "gloss-sources.json").write_text(
        json.dumps(manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(f"词条 {len(entries)}；已写出 {out} 与 gloss-sources.json")


if __name__ == "__main__":
    main()
