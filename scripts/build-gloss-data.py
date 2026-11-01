#!/usr/bin/env python3
"""从 Wiktionary wiktextract（kaikki.org）中文词条提取候选注释表 gloss.tsv。

来源与许可（结论见 docs/research-gloss-data.md）：
- kaikki.org per-language 下载（Chinese 词条 JSONL）；Wiktionary 文本 CC BY-SA 4.0
  ＋GFDL 双许可，提取数据按 CC BY-SA 4.0 分发并署名。
- 产物每行：词 <TAB> 注释（「词性. 释义 · 词性. 释义」，每词最多 2 个义项）。

质量规则（2026-10-31 随机样例审阅引入；2026-11-02 释义精简裁决收紧）：
- 简繁映射：Wiktionary 键多为繁体；带 Simplified-Chinese 标签的 forms 映射为
  简体键（覆盖会议→會議、银行→銀行这类常用词）。
- 噪声义项降级：方言／语域标签（粤语、闽南、文学、幽默、粗俗等）的义项排到
  非标签义项之后；alt-of 义项整条剔除（与正文重复）。
- character 不作词性展示：它是词条类别而非词性（char. 对用户不可读），
  该类词条只显示释义；其他无合格词性的词条同样只显示释义。
- 结构化词典标签不再透传：义项文本不再带 (hakka)／(rare) 一类标签前缀，
  方言／语域信息仅用于排序降级；纯括号标记（无实义正文）整条剔除。
- 简短义项：单条超过 MAX_SENSE_LEN 的义项不合格，整条剔除（不截断，
  避免制造错误释义）；在合格义项中按「非标签优先、原顺序优先」取前 2 条。
  没有合格短义项的词条不入表（等效留空，核心查不到即不显示注释）。
- 重复内容：同一词内按规范化文本（忽略大小写、空白与句尾句号）去重。
- 纯标点键（、。…）与 ideographic description 序列（⿰…）不收。

运行本脚本只是生成数据文件；把 gloss.tsv 打入输入法包 EngineData 前，必须先在
docs/third-party.md 登记来源、版本、哈希与署名义务（CC BY-SA 4.0、声明修改、
不添加额外限制），并以空表运行回归确认降级路径。

用法：python3 scripts/build-gloss-data.py kaikki-Chinese.jsonl.gz
"""
import gzip
import hashlib
import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent

POS_ABBREV = {
    "noun": "n.", "verb": "v.", "adj": "adj.", "adv": "adv.", "pron": "pron.",
    "prep": "prep.", "conj": "conj.", "interj": "intj.", "particle": "part.",
    "classifier": "cl.", "num": "num.", "phrase": "phr.", "proverb": "prov.",
    "name": "name",
}
# "character" 是词条类别，不进入词性缩写表：显示为纯释义。

# 单条义项长度上限：超过视为不合格短义项，整条剔除（不截断）。
# 候选窗注释区约容纳 60 个拉丁字符；64 留出词性前缀与分隔余量。
MAX_SENSE_LEN = 64
MAX_SENSES_PER_WORD = 2

# 这些标签的义项降级：常用词的首义经常是方言／语域用法，非标签义项优先。
NOISE_SUBSTRINGS = (
    "cantonese", "hokkien", "teochew", "hakka", "mandarin", "jin-", "wu-", "xiang",
    "gan-", "literary", "classical", "internet", "humorous", "vulgar",
    "euphemistic", "figurative", "slang", "dialect", "regional", "hong-kong",
)

# 强语域标签的义项整条剔除（不再只是降级）：俚语／粗俗／幽默／委呑义项
# 突然出现在候选窗会造成严重误读（样例审阅 2026-11-02：哲学第二条
# 「homosexual」）。方言、书面、网络、比喻等中性变体仍保留降级排序。
DROP_SUBSTRINGS = ("vulgar", "slang", "humorous", "euphemistic", "internet")

# 占位义项：无实义，不透传。
PLACEHOLDER_RE = re.compile(
    r"^The meaning of this term (is|may be) (uncertain|unknown)\.?$", re.IGNORECASE)


def is_noise(tags: list[str]) -> bool:
    lowered = [t.lower() for t in tags]
    return any(any(sub in t for sub in NOISE_SUBSTRINGS) for t in lowered)
SKIP_TAGS = {"alt-of", "obsolete", "archaic"}

# 分类器说明（量词搭配）：wiktextract 把量词列表写进义项文本，剥离后不影响释义。
# 量词词条本身的义项以「Classifier for …」开头时改写为可读的「measure word for …」。
CLASSIFIER_RE = re.compile(r"\s*\((?:Classifiers?|Measure words?)\s*:[^)]*\)", re.IGNORECASE)
LEADING_CLASSIFIER_RE = re.compile(r"^Classifiers?(?:\s+for|\s+of|:)?\s*", re.IGNORECASE)


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
    """返回 [(是否噪声标签, 文本)]；alt-of／obsolete／archaic 义项剔除。

    义项文本不再携带 (tag) 结构化标签前缀；超长与纯括号标记的义项整条剔除。
    (Classifier: …) 分类器说明不透传（用户不需要在候选窗里看量词搭配表）。"""
    pos = POS_ABBREV.get(entry.get("pos"), "")
    out = []
    for sense in entry.get("senses", []):
        tags = [t.lower() for t in sense.get("tags", [])]
        if any(t in SKIP_TAGS for t in tags):
            continue
        lowered = [t.lower() for t in tags]
        if any(any(sub in t for sub in DROP_SUBSTRINGS) for t in lowered):
            continue  # 强语域标签（俚语／粗俗等）整条剔除，不降级透传
        noise = is_noise(tags)
        for gloss in sense.get("glosses", []) or sense.get("raw_glosses", []):
            text = CLASSIFIER_RE.sub("", gloss).strip()
            text = LEADING_CLASSIFIER_RE.sub("measure word for ", text).strip()
            if not text or PLACEHOLDER_RE.match(text) or not presentable(text):
                continue
            text = f"{pos} {text}".strip()
            if len(text) > MAX_SENSE_LEN:
                continue  # 不合格短义项（含词性前缀）：整条剔除，不截断
            if not re.sub(r"\([^)]*\)|（[^）]*）", "", text).strip():
                continue  # 纯括号标记（方言／域标签残留）无阅读价值
            out.append((noise, text))
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
            if len(key) > 16 or not all("\u3400" <= c <= "\u9fff" for c in key):
                continue  # 键必须是纯 CJK 表意字符：排除 ⿰… 部件分解等不可读键
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
             "# 义务：署名 Wiktionary 贡献者、声明修改、衍生数据按 CC BY-SA 4.0 分发、不添加额外限制",
             f"# 规则：每词最多 {MAX_SENSES_PER_WORD} 条简短义项（单条 ≤{MAX_SENSE_LEN} 字符，超长整条剔除）；",
             "# character 词条不作词性展示；结构化标签不透传；非标签义项优先。"]
    for key in sorted(entries):
        bucket = sorted(entries[key], key=lambda item: item[0])  # 非噪声标签义项优先（稳定排序）
        seen: set[str] = set()
        picked: list[str] = []
        for _, text in bucket:
            # 规范化去重：忽略大小写、连续空白与句尾句号，避免同义变体重复。
            norm = re.sub(r"\s+", " ", text).strip().rstrip(".").lower()
            if norm in seen:
                continue
            seen.add(norm)
            picked.append(text)
            if len(picked) >= MAX_SENSES_PER_WORD:
                break
        if picked:
            lines.append(f"{key}\t{' · '.join(picked)}")
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
