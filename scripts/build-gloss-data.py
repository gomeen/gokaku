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
- 词性层（2026-11-03 用户裁决「单字也要显示词性」）：Wiktionary 字条目
  （pos=character）与 name 等无合格词性词条不再纯释义，改用 jieba 词库
  （MIT，348k 条、词频排序）取该字最高频词条的词性标注，映射为缩写前缀
  （n.／v.／adj.／adv.／pron.／cl.／part. 等），每条义项带前缀。
- 覆盖补缺（2026-11-03）：Wiktionary 缺失的单字（軍→军类软重定向无义项）
  用 CC-CEDICT（CC BY-SA 4.0，当前 dump）的简体单字条目补义项，
  义项按 / 分条取前 2，同标词性前缀，青简样式「n. army · n. military」。
- 结构化词典标签不再透传：义项文本不再带 (hakka)／(rare) 一类标签前缀，
  方言／语域信息仅用于排序降级；纯括号标记（无实义正文）整条剔除。
- 注释清洗 v7（2026-11-03 用户裁决不显示括号）：括号内容一律移除；
  synonym of／alternative form of 等字形指代义项剔除；截断态即行尾；
  分隔符统一为点号 ·；
  义项正文内长括号消歧说明（含括号 >18 字符）整体移除、短括号保留；
  分号同义枚举（≥3 项）只保留前 2 项加 …；
  单条超 MAX_SENSE_LEN 时词边界截断加 …（替代旧「整条剔除」）；
  拼接总长超 MAX_JOINED_LEN 时只保留第一条。在合格义项中按
  「非标签优先、原顺序优先」取前 2 条；没有合格义项的词条不入表。
- 重复内容：同一词内按规范化文本（忽略大小写、空白与句尾句号）去重。
- 纯标点键（、。…）与 ideographic description 序列（⿰…）不收。

运行本脚本只是生成数据文件；把 gloss.tsv 打入输入法包 EngineData 前，必须先在
 docs/third-party.md 登记来源、版本、哈希与署名义务（CC BY-SA 4.0、声明修改、
不添加额外限制），并以空表运行回归确认降级路径。

用法：python3 scripts/build-gloss-data.py kaikki-Chinese.jsonl.gz \
        [--cedict cedict.txt.gz] [--jieba dict.txt]
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
}
# "character" 是词条类别，不进入词性缩写表：改由下方 jieba 词性层补标。

# jieba 词性标注 → 展示缩写（2026-11-03 词性层）。jieba 词库 MIT 许可，
# 词性体系见 jieba/__init__.py 词性对照表；这里只映射用户可读的缩写。
JIEBA_LABELS = {
    "n": "n.", "nr": "n.", "ns": "n.", "nt": "n.", "nz": "n.", "nl": "n.",
    "ng": "n.", "t": "t.", "s": "n.", "f": "n.", "v": "v.", "vd": "v.",
    "vn": "v.", "vi": "v.", "vt": "v.", "vg": "v.", "a": "adj.", "an": "adj.",
    "ag": "adj.", "ad": "adv.", "d": "adv.", "dg": "adv.", "r": "pron.",
    "rg": "pron.", "m": "num.", "mg": "num.", "q": "cl.", "qn": "cl.", "c": "conj.",
    "p": "prep.", "u": "part.", "uj": "part.", "ul": "part.", "ud": "part.",
    "uv": "part.", "uz": "part.", "ug": "part.", "i": "phr.", "l": "phr.",
    "j": "abbr.", "eng": "eng.", "y": "intj.", "e": "intj.", "o": "onom.",
    # 2026-11-03 未映射标签审计补齐：zg 状态词（很／猛然）读起来副词化；
    # g 学术语素、nrt／nrfg 音译人名归名词；b／z 区别词归形容词；tg 时语素、
    # x 非语素字（无词性）与前后接成分 h／k 保持不标注。
    "zg": "adv.", "g": "n.", "b": "adj.", "z": "adj.", "tg": "t.",
    "nrt": "n.", "nrfg": "n.",
}
CEDICT_GLOSS_SPLIT_RE = re.compile(r"\A(\S+)\s+(\S+)\s+\[([^\]]*)\]\s+(.*)\Z")

# 清洗规则 v3（2026-11-03 用户裁决「尽量显示全、不遗漏重要信息」）：
# R1 义项正文内的长括号消歧说明（含括号 >18 字符）整体移除，短括号保留；
# R2 单条超 MAX_SENSE_LEN 时在词边界截断加省略号（替代旧「整条剔除」，
#    截断以 … 显式标记，不制造完整释义假象）；
# R1.5 分号同义枚举（≥3 项）只保留前 2 项加 …（主义项在前不丢主释义）。
# R3 拼接总长超 MAX_JOINED_LEN 时只保留第一条义项。
# R5 分隔符统一：义项内同义枚举的分号（含全角）统一为点号 · 分隔。
# R6 行内不出现省略号：同义枚举只取首项、超长静默词边界截断（2026-11-03
#    用户裁决「希望可以显示全」，限制发生在生成侧而非展示侧）。
# 规则全部编码在本脚本，重新生成数据时自动按同规则执行（可复现）。
# 候选窗注释区约容纳 45 个拉丁字符；36 留出词性前缀余量，46 为拼接上限。
MAX_SENSE_LEN = 36
MAX_JOINED_LEN = 46
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


REFERENCE_OF_RE = re.compile(
    r"^(synonym|alternative form|variant|short for|traditional|simplified)\b", re.IGNORECASE)
# 截断点悬空虚词（截到行尾时把 a／of／the 一类残尾一起去掉）
DANGLING_WORDS = {"a", "an", "the", "of", "to", "in", "at", "for", "with", "by", "and", "or"}


def senses_of(entry: dict, extra_pos: str = "") -> list[tuple[bool, str, bool]]:
    """返回 [(是否噪声标签, 文本, 是否截断态)]；alt-of／obsolete／archaic 义项剔除。

    清洗规则 v7（2026-11-03）：括号内容一律移除（含短括号，用户裁决不显示
    括号）；synonym of／alternative form of 一类字形指代义项剔除（不是释义）；
    超长义项静默词边界截断并标记截断态（供 R4「截断即行尾」使用）。
    (Classifier: …) 分类器说明不透传。
    词性层 v8（2026-11-03）：Wiktionary 词性缺失（character／name 等）时
    用 jieba 词性层前缀 extra_pos（每条义项带前缀，青简样式）。"""
    pos = POS_ABBREV.get(entry.get("pos"), "") or extra_pos
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
            # R1 括号内容一律移除（2026-11-03 用户裁决不显示括号；
            # 消歧说明属词典细节，核心释义在括号外）；未闭合括号残尾一并去掉。
            text = re.sub(r"\s*\([^)]*\)", "", text)
            text = re.sub(r"\s*（[^）]*）", "", text)
            text = re.sub(r"\([^)]*$", "", text).rstrip()
            # 字形指代义项剔除（synonym of X／alternative form of X 等，
            # 与 alt-of 同类：与正文重复，不是释义）
            if REFERENCE_OF_RE.match(text.strip()):
                continue
            # R1.5 分号同义枚举只取第 1 项（Wiktionary 义项常把同义词全排开，
            # 候选窗里是噪音；首项＝主义项，行内不出现省略号）。
            text = text.split("; ")[0]
            text = text.strip()
            if not text or PLACEHOLDER_RE.match(text) or not presentable(text):
                continue
            text = f"{pos} {text}".strip()
            if not re.sub(r"\([^)]*\)|（[^）]*）", "", text).strip():
                continue  # 纯括号标记（方言／域标签残留）无阅读价值
            # R2 词边界静默截断并标记截断态（截断点悬空虚词一并去掉）
            truncated = len(text) > MAX_SENSE_LEN
            if truncated:
                cut = text[:MAX_SENSE_LEN]
                sp = cut.rfind(" ")
                if sp > MAX_SENSE_LEN // 2:
                    cut = cut[:sp]
                words = cut.rstrip(" ;:,").split(" ")
                while words and words[-1].lower() in DANGLING_WORDS:
                    words.pop()
                text = " ".join(words)
            # R5 分隔符统一为点号（2026-11-03 用户裁决：不同词之间用 · 分隔，
            # 与词库条目的点号样式一致；分号枚举与全角分号一并归一）。
            text = text.replace("; ", " · ").replace("；", " · ")
            out.append((noise, text, truncated))
    return out


def presentable(text: str) -> bool:
    """允许 ASCII、CJK 统一表意、CJK 标点（、。〔〕「」）与全角形式（（）／：）。
    全角标点出现在 Classifier 标记（如 個／个）里，不能因它丢掉整条义项。
    …（U+2026）是清洗规则的截断标记、·（U+00B7）是分隔符，同样放行。"""
    for c in text:
        cp = ord(c)
        if cp < 128 or c in ("\u2026", "\u00b7"):
            continue
        if "\u3400" <= c <= "\u9fff" or "\u3000" <= c <= "\u303f" or "\uff00" <= c <= "\uffef":
            continue
        return False
    return True


def load_jieba_pos(path: Path | None) -> dict[str, str]:
    """jieba 词库（词 频率 词性）→ 单字 → 展示缩写。取该字最高频词条的词性：
    军→n.、高→adj.、你→pron.、个→cl.、了→part.、均→adv.。只收单 CJK 字。"""
    if path is None:
        return {}
    best: dict[str, tuple[int, str]] = {}
    for line in path.read_text(encoding="utf-8").splitlines():
        parts = line.split(" ")
        if len(parts) != 3:
            continue
        word, freq_s, tag = parts
        if len(word) != 1 or not ("\u3400" <= word <= "\u9fff"):
            continue
        label = JIEBA_LABELS.get(tag)
        if not label:
            continue
        try:
            freq = int(freq_s)
        except ValueError:
            continue
        if word not in best or freq > best[word][0]:
            best[word] = (freq, label)
    return {w: label for w, (_, label) in best.items()}


def load_cedict_single(path: Path | None) -> dict[str, list[str]]:
    """CC-CEDICT（繁 簡 [拼音] /释义1/释义2/…）→ 简体单字 → 义项列表（≤2）。
    跳过 CL: 量词搭配、see 交叉引用、variant of 字形指代、空条；
    每条义项先过括号／首项／presentable 清洗（与 Wiktionary 同规则）。"""
    if path is None:
        return {}
    opener = gzip.open if path.suffix == ".gz" else open
    out: dict[str, list[str]] = {}
    with opener(path, "rt", encoding="utf-8", errors="replace") as stream:
        for line in stream:
            if line.startswith("#"):
                continue
            m = CEDICT_GLOSS_SPLIT_RE.match(line.strip())
            if not m:
                continue
            simplified = m.group(2)
            if len(simplified) != 1 or not ("\u3400" <= simplified <= "\u9fff"):
                continue  # 只补 Wiktionary 缺失的单字，双字词覆盖不动
            for gloss in m.group(4).strip("/").split("/"):
                gloss = gloss.strip()
                if not gloss or gloss.startswith(("CL:", "see ", "arch.", "used in ", "old variant of")):
                    continue
                if re.match(r"^(old[ -])?variant of", gloss):
                    continue
                text = re.sub(r"\s*\([^)]*\)", "", gloss)
                text = re.sub(r"\([^)]*$", "", text).rstrip()
                text = text.split(";")[0].strip()
                if not text or not presentable(text):
                    continue
                # 拼音残片（括号剥离后剩下的 ge4 这类音节）不是释义
                if re.search(r"[a-z]+\d", text) or text in ("tw", "prc", "e.g."):
                    continue
                bucket = out.setdefault(simplified, [])
                if text not in bucket:
                    bucket.append(text)
                if len(bucket) >= MAX_SENSES_PER_WORD:
                    break
    return out


def main() -> None:
    args = [a for a in sys.argv[1:]]
    cedict_path: Path | None = None
    jieba_path: Path | None = None
    if "--cedict" in args:
        i = args.index("--cedict")
        cedict_path = Path(args[i + 1])
        del args[i:i + 2]
    if "--jieba" in args:
        i = args.index("--jieba")
        jieba_path = Path(args[i + 1])
        del args[i:i + 2]
    if len(args) != 1:
        print(__doc__)
        sys.exit(2)
    source = Path(args[0])
    opener = gzip.open if source.suffix == ".gz" else open
    jieba_pos = load_jieba_pos(jieba_path)
    cedict_single = load_cedict_single(cedict_path)
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
            found = senses_of(entry, extra_pos=jieba_pos.get(key, ""))
            if not found:
                continue
            bucket = entries.setdefault(key, [])
            for item in found:
                if item not in bucket:
                    bucket.append(item)
    # 覆盖补缺：Wiktionary 缺失的单字（軍→军 软重定向无义项这类）用
    # CC-CEDICT 义项＋jieba 词性合成条目，每条义项带词性前缀（青简样式）。
    supplement = 0
    for key, glosses in cedict_single.items():
        if key in entries:
            continue
        label = jieba_pos.get(key, "n.")
        bucket: list[tuple[bool, str, bool]] = []
        for text in glosses:
            item = (False, f"{label} {text}".strip(), False)
            if item not in bucket:
                bucket.append(item)
        if bucket:
            entries[key] = bucket
            supplement += 1
    out = ROOT / "resources" / "gloss.tsv"
    out.parent.mkdir(parents=True, exist_ok=True)
    lines = ["# gloss.tsv — 词性＋译文注释（Wiktionary/wiktextract，CC BY-SA 4.0；",
             "# 单字词性层 jieba（MIT）；Wiktionary 缺失单字由 CC-CEDICT（CC BY-SA 4.0）补义项）",
             f"# 来源：kaikki.org Chinese 提取；文件 {source.name} sha256={sha256(source)}",
             (f"# 词性层：jieba dict.txt sha256={sha256(jieba_path)}" if jieba_path else "# 词性层：未提供"),
             (f"# 补缺源：CC-CEDICT {cedict_path.name} sha256={sha256(cedict_path)}" if cedict_path else "# 补缺源：未提供"),
             "# 义务：署名 Wiktionary／CC-CEDICT 贡献者、声明修改、衍生数据按 CC BY-SA 4.0 分发、不添加额外限制",
             f"# 规则：每词最多 {MAX_SENSES_PER_WORD} 条简短义项（单条 ≤{MAX_SENSE_LEN} 字符，超长整条剔除）；",
             "# character 词条词性由 jieba 补标；结构化标签不透传；非标签义项优先。"]
    for key in sorted(entries):
        bucket = sorted(entries[key], key=lambda item: item[0])  # 非噪声标签义项优先（稳定排序）
        seen: set[str] = set()
        picked: list[tuple[str, bool]] = []  # (文本, 是否截断态)
        for _, text, truncated in bucket:
            # 规范化去重：忽略大小写、连续空白与句尾句号，避免同义变体重复。
            norm = re.sub(r"\s+", " ", text).strip().rstrip(".").lower()
            if norm in seen:
                continue
            seen.add(norm)
            picked.append((text, truncated))
            # R4 截断态义项即行尾：不再追加后续义项（避免截断残尾后拼接混淆）
            if truncated:
                break
            if len(picked) >= MAX_SENSES_PER_WORD:
                break
        if picked:
            joined = " · ".join(text for text, _ in picked)
            # R3 拼接总长上限：放下两条时丢第二条（静默词边界截去）
            if len(joined) > MAX_JOINED_LEN:
                cut = joined[:MAX_JOINED_LEN]
                sp = cut.rfind(" ")
                if sp > MAX_JOINED_LEN // 2:
                    cut = cut[:sp]
                joined = cut.rstrip(" ;:,· ")
            lines.append(f"{key}\t{joined}")
    out.write_text("\n".join(lines) + "\n", encoding="utf-8")
    manifest = {
        "description": "候选窗「词性＋译文」注释（Wiktionary/wiktextract 中文词条，英文释义；"
                       "单字词性层 jieba；Wiktionary 缺失单字由 CC-CEDICT 补义项）",
        "license": {
            "wiktionary": "CC BY-SA 4.0（双许可取 CC 一支）；署名 Wiktionary contributors，声明修改，逐词条原文 URI",
            "wiktextract": "MIT（提取工具，不覆盖输出数据许可）",
            "jieba": "MIT（词性标注层，来自 jieba/dict.txt，github.com/fxsjy/jieba）",
            "cc-cedict": "CC BY-SA 4.0（Wiktionary 缺失单字补义项，mdbg/chineselanguageproject dump）",
        },
        "sources": {
            "kaikki": {"file": source.name, "bytes": source.stat().st_size, "sha256": sha256(source),
                       "url": "https://kaikki.org/dictionary/Chinese/"},
            **({"jieba": {"file": jieba_path.name, "bytes": jieba_path.stat().st_size,
                          "sha256": sha256(jieba_path),
                          "url": "https://github.com/fxsjy/jieba"}} if jieba_path else {}),
            **({"cc-cedict": {"file": cedict_path.name, "bytes": cedict_path.stat().st_size,
                              "sha256": sha256(cedict_path),
                              "url": "https://www.mdbg.net/chinese/dictionary?page=cc-cedict"}} if cedict_path else {}),
        },
        "entry_count": len(entries),
        "single_char_supplement": supplement,
        "cleaningRules": {"version": "v8", "date": "2026-11-03",
                          "rules": ["括号内容一律移除", "分号同义枚举只取首项",
                                    "synonym of/alternative form of 等字形指代义项剔除",
                                    "单条≤36字符静默词边界截断(截断态即行尾)",
                                    "拼接总长≤46字符",
                                    "分隔符统一为点号·",
                                    "词性层：jieba 补标 character 等无词性词条",
                                    "覆盖补缺：Wiktionary 缺失单字由 CC-CEDICT+jieba 合成"],
                          "script": "scripts/build-gloss-data.py（规则即代码，重跑可复现）"},
        "output_sha256": sha256(out),
    }
    (ROOT / "resources" / "gloss-sources.json").write_text(
        json.dumps(manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(f"词条 {len(entries)}；已写出 {out} 与 gloss-sources.json")


if __name__ == "__main__":
    main()
