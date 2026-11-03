#!/usr/bin/env python3
"""构建翻译表达资源（审核片）——CC-CEDICT 义项 ＋ 独立日常表达清单选词。

设计边界（docs/translation-strategy-decision.md）：
  - 只从有明确许可的词典条目派生；每行保留方向、来源词头、义项数与审核状态；
  - 选词来自独立类别清单（resources/translation/selection-seeds.txt）与词频，
    不从任何评测集的失败样例里补答案；
  - 同一词头存在多个互不一致的义项时整条不进资源（不把某一个义项当成唯一答案）；
  - 英文→中文方向允许最多 3 个常用中文译法，按词频取首要译法并保留备选，
    运行期任一审阅译法被模型产出即视为义项对齐；
  - 单条表达只在「完整输入精确命中」时直接使用。

用法：
  python3 scripts/build-translation-expressions.py            # 构建并写资源
  python3 scripts/build-translation-expressions.py --print    # 只打印供审阅
"""
import argparse
import gzip
import hashlib
import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
CEDICT = Path.home() / 'Library/Caches/Gogaku/kaikki/cedict_ts.u8.gz'
JIEBA = Path.home() / 'Library/Caches/Gogaku/jieba-dict.txt'
ENGLISH_WORDS = ROOT / 'resources/english-words.txt'
SEEDS = ROOT / 'resources/translation/selection-seeds.txt'
OUT_DIR = ROOT / 'resources/translation'
REVIEW_LOG = OUT_DIR / 'review-log.tsv'

CEDICT_LICENSE = 'CC BY-SA 4.0'
CEDICT_URL = 'https://www.mdbg.net/chinese/dictionary?page=cc-cedict'

# CC-CEDICT 的元数据义项（分类词、异体、地名/姓氏等）不是可提交译文。
META = re.compile(
    r'^(CL:|Taiwan pr\.|also pr\.|old variant|variant of|surname|abbr\. for|see also|see |'
    r'used in|erhua|archaic variant|Japanese variant|also written)'
)
FUNCTION_WORDS = {
    'a', 'an', 'the', 'and', 'or', 'of', 'to', 'in', 'on', 'at', 'for', 'with', 'by', 'from',
    'that', 'this', 'these', 'those', 'it', 'he', 'she', 'they', 'we', 'you', 'i', 'is', 'are',
    'was', 'were', 'be', 'been', 'being', 'do', 'does', 'did', 'have', 'has', 'had', 'will',
    'would', 'can', 'could', 'should', 'shall', 'may', 'might', 'must', 'not', 'no', 'yes',
    'so', 'if', 'then', 'than', 'as', 'but', 'also', 'very', 'more', 'most', 'much', 'many',
    'some', 'any', 'all', 'each', 'every', 'both', 'other', 'another', 'such', 'own', 'same',
    'only', 'just', 'up', 'down', 'out', 'off', 'over', 'under', 'again', 'further', 'once',
    'here', 'there', 'when', 'where', 'why', 'how', 'what', 'which', 'who', 'whom', 'whose',
    'one', 'ones', 'etc', 'sth', 'sb', 'after', 'before', 'during', 'without', 'within',
    'about', 'above', 'below', 'between', 'through', 'against', 'toward', 'towards', 'upon',
    'into', 'onto', 'since', 'until', 'till', 'while', 'though', 'although', 'unless',
    'whether', 'either', 'neither', 'nor', 'yet', 'still', 'already', 'ever', 'never',
    'always', 'often', 'sometimes', 'usually', 'soon', 'later', 'now', 'then', 'too',
    'him', 'her', 'hers', 'his', 'them', 'their', 'theirs', 'us', 'our', 'ours', 'me', 'my',
    'mine', 'himself', 'herself', 'itself', 'themselves', 'yourself', 'someone', 'something',
    'anything', 'nothing', 'everyone', 'everything', 'nobody', 'anybody', 'somebody',
    'somewhere', 'everywhere', 'nowhere', 'whatever', 'whoever', 'whenever',
}
MAX_SENSE_GROUPS = 3
MAX_SLICE = 300


def sha256(path):
    digest = hashlib.sha256()
    with Path(path).open('rb') as handle:
        for chunk in iter(lambda: handle.read(1 << 20), b''):
            digest.update(chunk)
    return digest.hexdigest()


def clean_senses(gloss):
    out = []
    for sense in gloss.split('/'):
        sense = sense.strip()
        if not sense or META.match(sense):
            continue
        sense = re.sub(r'^\([^)]*\)\s*', '', sense)  # 去掉前置括注（(medicine) 等用法标签）
        sense = re.sub(r'\([^)]*\)', '', sense)       # 去掉行内括注
        sense = sense.strip().strip('!').strip()
        if sense:
            out.append(sense)
    return out


def clean_rendering(text):
    text = text.strip()
    had_to = text.lower().startswith('to ')
    if had_to:
        text = text[3:]
    text = text.lower()
    text = text.split(',')[0]  # 「Excuse me, may I ask…」取逗号前主表达
    text = re.sub(r'\s+', ' ', text).strip(' .,!?')
    return text, had_to


def en_renderings(rec):
    """该词头首个义项组的全部英文译法（供英文→中文索引用）。"""
    out = []
    seen = set()
    for sense in rec['senses']:
        for text, had_to in renderings(sense):
            if text in seen:
                continue
            seen.add(text)
            out.append((text, had_to))
    return out


def stem(token):
    token = token.lower()
    for suffix in ('ing', 'ed', 'es', 's'):
        if len(token) > len(suffix) + 2 and token.endswith(suffix):
            return token[: -len(suffix)]
    return token


def sense_groups(senses):
    """把词性变体（to thank / thanks / thank you）并成同一义项组。

    只比较实词：the/to/after 这类功能词会让两个不相干的义项凑成一组
    （后天：the day after tomorrow 与 life after birth）。
    """
    groups = []
    for sense in senses:
        words = {
            stem(word)
            for word in re.findall(r"[a-z']+", sense.lower())
            if word not in FUNCTION_WORDS
        }
        if not words:
            words = {stem(sense.split()[0].lower())}
        merged = False
        for group in groups:
            if words & group['words']:
                group['words'] |= words
                group['senses'].append(sense)
                merged = True
                break
        if not merged:
            groups.append({'words': words, 'senses': [sense]})
    return groups


def renderings(sense):
    out = []
    for part in sense.split(';'):
        text, had_to = clean_rendering(part)
        if not text:
            continue
        if not re.fullmatch(r"[a-z][a-z' -]*", text):
            continue
        if len(text) > 30 or len(text.split()) > 4:
            continue
        out.append((text, had_to))
    return out


def pick_target(groups):
    """第一个义项组里最简的可提交译文：优先非 to 不定式、非复数/三单的短形式。"""
    candidates = []
    for sense in groups[0]['senses']:
        candidates.extend(renderings(sense))
    if not candidates:
        return None
    texts = {text for text, _had_to in candidates}
    ordered = sorted(
        range(len(candidates)),
        key=lambda i: (
            candidates[i][1],
            len(candidates[i][0].split()),
            1 if (candidates[i][0].endswith('s') and candidates[i][0][:-1] in texts) else 0,
            i,
        ),
    )
    return candidates[ordered[0]][0]


def load_cedict(path):
    entries = []
    with gzip.open(path, 'rt', encoding='utf-8') as handle:
        for line in handle:
            if line.startswith('#'):
                continue
            match = re.match(r'^(\S+)\s+(\S+)\s+\[([^\]]*)\]\s+/(.*)/\s*$', line.rstrip('\n'))
            if not match:
                continue
            trad, simp, pinyin, gloss = match.groups()
            entries.append((trad, simp, pinyin, gloss))
    return entries


def load_jieba(path):
    freq = {}
    with Path(path).open(encoding='utf-8') as handle:
        for line in handle:
            parts = line.split()
            if len(parts) >= 2:
                try:
                    freq[parts[0]] = int(parts[1])
                except ValueError:
                    continue
    return freq


def load_review_log(path):
    """review-log.tsv：方向\t源表达\t处置(reject|override)\t目标\t理由。

    只有被否决或改写的条目需要记录；未记录即视为整表复核通过。
    """
    decisions = {}
    if not path.is_file():
        return decisions
    for line in path.read_text(encoding='utf-8').splitlines():
        if not line.strip() or line.lstrip().startswith('#'):
            continue
        fields = line.split('\t')
        if len(fields) >= 3 and fields[0] in ('en-zh', 'zh-en'):
            decisions[(fields[0], fields[1])] = {
                'decision': fields[2].strip(),
                'target': fields[3].strip() if len(fields) > 3 else '',
                'reason': fields[4].strip() if len(fields) > 4 else '',
            }
    return decisions


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--cedict', type=Path, default=CEDICT)
    parser.add_argument('--jieba', type=Path, default=JIEBA)
    parser.add_argument('--print', dest='print_only', action='store_true')
    args = parser.parse_args()

    for path in (args.cedict, args.jieba, ENGLISH_WORDS, SEEDS):
        if not path.is_file():
            raise SystemExit('missing input: %s' % path)

    seeds_zh, seeds_en = set(), set()
    for line in SEEDS.read_text(encoding='utf-8').splitlines():
        if not line.strip() or line.lstrip().startswith('#'):
            continue
        fields = line.split('\t')
        if len(fields) < 2:
            continue
        category, word = fields[0].strip(), fields[1].strip()
        (seeds_en if category == 'en' else seeds_zh).add(word)

    jieba = load_jieba(args.jieba)
    english_rank = {
        word.strip(): index
        for index, word in enumerate(ENGLISH_WORDS.read_text(encoding='utf-8').splitlines())
        if word.strip()
    }
    entries = load_cedict(args.cedict)

    # 1) 每个简化词头提出一个候选译文；互不一致的多义词头整条剔除。
    grouped = {}
    proper_nouns = 0
    for trad, simp, pinyin, gloss in entries:
        if pinyin[:1].isupper():
            proper_nouns += 1
            continue  # 专名条目（Apple 公司、地名）不进入日常表达资源
        senses = clean_senses(gloss)
        if not senses:
            continue
        groups = sense_groups(senses)
        target = pick_target(groups)
        if target is None:
            continue
        grouped.setdefault(simp, []).append({
            'target': target,
            'senseGroups': len(groups),
            'senses': senses[:4],
            'pinyin': pinyin,
            'trad': trad,
        })
    proposed = {}
    ambiguous = 0
    for simp, recs in grouped.items():
        if len({rec['target'] for rec in recs}) > 1:
            ambiguous += 1
            continue
        proposed[simp] = recs[0]
    print('cedict entries: %d (proper nouns skipped %d), unambiguous headwords: %d, '
          'ambiguous skipped: %d' % (len(entries), proper_nouns, len(proposed), ambiguous))

    def is_common(zh):
        return zh in seeds_zh or jieba.get(zh, 0) >= 1

    # 中文→英文：只保留义项组 ≤ 3 的词头（必须挑一个英文译法）。
    eligible = {
        zh: rec
        for zh, rec in proposed.items()
        if rec['senseGroups'] <= MAX_SENSE_GROUPS and is_common(zh)
    }
    # 英文→中文：中文词的义项多寡不影响「英文→正确中文」的判断，
    # 因此不做义项组上限；用首个义项组的全部译法建索引，主译法命中优先。
    en_index = {}
    for zh, rec in proposed.items():
        if not is_common(zh) or len(zh) > 6:
            continue
        for text, _had_to in en_renderings(rec):
            en_index.setdefault(text, []).append(zh)
    en_map = {}
    for en, zhs in en_index.items():
        if en in FUNCTION_WORDS or len(en) < 2:
            continue
        floor = 1 if en in seeds_en else 300  # 类别清单内的表达允许较低的词头词频
        ranked = []
        for zh in set(zhs):
            freq = jieba.get(zh, 0)
            if freq < floor:
                continue
            rec = proposed[zh]
            # 首片以词频为主序（常用词优先），再偏好非单字、主译法命中、义项少。
            ranked.append((
                -freq,
                1 if len(zh) == 1 else 0,
                0 if rec['target'] == en else 1,
                rec['senseGroups'],
                zh,
            ))
        if not ranked:
            continue
        ranked.sort()
        en_map[en] = [row[-1] for row in ranked[:3]]

    seeds_zh = seeds_zh
    zh_rows = []
    for zh, rec in eligible.items():
        target = rec['target']
        if target in FUNCTION_WORDS or len(target.split()) > 4:
            continue
        if not (2 <= len(zh) <= 6):
            continue
        seed = zh in seeds_zh
        freq = jieba.get(zh, 0)
        if not seed and freq < 4000:
            continue
        zh_rows.append((0 if seed else 1, -freq, zh, target, rec))
    zh_rows.sort()
    zh_slice = zh_rows[:MAX_SLICE]

    en_rows = []
    for en, zhs in en_map.items():
        if en not in seeds_en:
            continue  # 英文→中文首片只提交类别清单内的表达；其余靠模型＋反向评分
        rank = english_rank.get(en, 10 ** 9)
        en_rows.append((0 if seed else 1, rank, en, zhs))
    en_rows.sort()
    en_slice = en_rows[:MAX_SLICE]

    decisions = load_review_log(REVIEW_LOG)
    headwords = {simp for _trad, simp, _pinyin, _gloss in entries}
    attested = {}
    for trad, simp, pinyin, gloss in entries:
        senses = clean_senses(gloss)
        if not senses:
            continue
        bucket = attested.setdefault(simp, set())
        for sense in senses:
            for text, _had_to in renderings(sense):
                bucket.add(text)
    problems = []
    for (direction, source), decision in decisions.items():
        if decision['decision'] != 'override' or not decision['target']:
            continue
        target = decision['target']
        if direction == 'en-zh':
            if target not in headwords:
                problems.append('en-zh %s→%s：目标不是 CC-CEDICT 词头' % (source, target))
            elif source not in attested.get(target, set()):
                problems.append('en-zh %s→%s：目标词头未收录该英文译法' % (source, target))
        else:
            if target not in attested.get(source, set()):
                alternatives = sorted(attested.get(source, set()))[:8]
                problems.append('zh-en %s→%s：目标不在该词头译法中（可选 %s）'
                                % (source, target, alternatives))
    for problem in problems:
        print('review-override unattested: ' + problem)

    def apply_review(rows, direction, source_index):
        out = []
        for row in rows:
            source = row[source_index]
            decision = decisions.get((direction, source))
            if decision and decision['decision'] == 'reject':
                continue
            if decision and decision['decision'] == 'override' and decision['target']:
                row = list(row)
                if direction == 'en-zh':
                    row[3] = [decision['target']] + [z for z in row[3] if z != decision['target']]
                else:
                    row[3] = decision['target']
            out.append(tuple(row))
        return out

    zh_final = apply_review(zh_slice, 'zh-en', 2)
    en_final = apply_review(en_slice, 'en-zh', 2)

    print('zh-en slice: %d (rejected %d) | en-zh slice: %d (rejected %d)'
          % (len(zh_final), len(zh_slice) - len(zh_final),
             len(en_final), len(en_slice) - len(en_final)))

    if args.print_only:
        print('\n=== en-zh ===')
        for _, _, en, zhs in en_final:
            extra = ('  [备选: %s]' % '|'.join(zhs[1:])) if len(zhs) > 1 else ''
            print('%s\t%s%s' % (en, zhs[0], extra))
        print('\n=== zh-en ===')
        for _, _, zh, target, rec in zh_final:
            print('%s\t%s\t(%d 组)' % (zh, target, rec['senseGroups']))
        return 0

    # 3) 写资源文件。
    cedict_sha = sha256(args.cedict)
    lines = [
        '# expressions.tsv — 审核过的翻译表达资源（首片）',
        '# 方向\t源表达\t译入表达\t义项组数\tCC-CEDICT 词头\t拼音\t审核状态\t备选译法',
        '# 来源：CC-CEDICT（%s，%s），sha256=%s' % (CEDICT_LICENSE, CEDICT_URL, cedict_sha),
        '# 选词：resources/translation/selection-seeds.txt 类别清单 + jieba 词频；不从评测集补答案',
        '# 义务：署名 CC-CEDICT 贡献者、声明修改、本衍生数据按 CC BY-SA 4.0 分发',
    ]
    for _, _, en, zhs in en_final:
        lines.append('en-zh\t%s\t%s\t1\t%s\t-\taudited-v1\t%s'
                     % (en, zhs[0], zhs[0], '|'.join(zhs[1:])))
    for _, _, zh, target, rec in zh_final:
        lines.append('zh-en\t%s\t%s\t%d\t%s\t%s\taudited-v1\t'
                     % (zh, target, rec['senseGroups'], rec['trad'], rec['pinyin']))
    (OUT_DIR / 'expressions.tsv').write_text('\n'.join(lines) + '\n', encoding='utf-8')

    manifest = {
        'schemaVersion': 1,
        'version': '2026-11-04.1',
        'kind': 'audited-translation-expressions',
        'directions': ['en-zh', 'zh-en'],
        'license': CEDICT_LICENSE,
        'attribution': 'CC-CEDICT contributors（%s），本文件为衍生数据并声明修改' % CEDICT_URL,
        'sources': {
            'cc-cedict': {
                'file': args.cedict.name,
                'bytes': args.cedict.stat().st_size,
                'sha256': cedict_sha,
                'entries': len(entries),
                'url': CEDICT_URL,
            },
            'jieba': {'file': args.jieba.name, 'sha256': sha256(args.jieba),
                      'url': 'https://github.com/fxsjy/jieba', 'license': 'MIT'},
            'english-words': {'file': ENGLISH_WORDS.name, 'sha256': sha256(ENGLISH_WORDS),
                              'note': 'wordfreq 频序，SCOWL 词表；见 resources/licenses'},
        },
        'selection': {
            'seeds': str(SEEDS.relative_to(ROOT)),
            'seedsZh': len(seeds_zh),
            'seedsEn': len(seeds_en),
            'maxSenseGroups': MAX_SENSE_GROUPS,
            'sliceCap': MAX_SLICE,
            'properNounPolicy': '拼音首字母大写的专名条目不进入资源',
            'conflictPolicy': '同一词头存在互不一致义项时整条不进资源',
            'zhPolicy': '2–6 字词头；类别清单或 jieba 词频 ≥ 4000；义项组 ≤ 3',
            'enPolicy': '唯一英文串→最多 3 个常用中文译法，按词频取首要；类别清单或英文词频前 8000',
            'note': '完整输入精确命中才直接使用；义项集合保留在证据里',
        },
        'counts': {
            'en-zh': len(en_final),
            'zh-en': len(zh_final),
            'reviewedExceptions': len(decisions),
            'rejectedByReview': sum(1 for d in decisions.values() if d['decision'] == 'reject'),
            'overriddenByReview': sum(1 for d in decisions.values()
                                      if d['decision'] == 'override'),
            'overrideUnattested': len(problems),
            'unambiguousHeadwords': len(proposed),
            'ambiguousSkipped': ambiguous,
            'properNounsSkipped': proper_nouns,
            'englishKeys': len(en_map),
        },
        'review': {
            'status': 'audited-v1',
            'log': 'review-log.tsv',
            'logSha256': sha256(REVIEW_LOG) if REVIEW_LOG.is_file() else None,
            'policy': '规则筛选＋整表逐条人工复核；否决与改写记入 review-log.tsv，未记录即复核通过',
        },
        'files': {
            'expressions.tsv': sha256(OUT_DIR / 'expressions.tsv'),
            'templates.json': sha256(OUT_DIR / 'templates.json')
            if (OUT_DIR / 'templates.json').is_file() else None,
            'brands.tsv': sha256(OUT_DIR / 'brands.tsv')
            if (OUT_DIR / 'brands.tsv').is_file() else None,
        },
    }
    (OUT_DIR / 'manifest.json').write_text(
        json.dumps(manifest, ensure_ascii=False, indent=1) + '\n', encoding='utf-8')
    print('wrote %s and %s' % (OUT_DIR / 'expressions.tsv', OUT_DIR / 'manifest.json'))
    return 0


if __name__ == '__main__':
    sys.exit(main())
