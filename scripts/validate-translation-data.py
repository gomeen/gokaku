#!/usr/bin/env python3
"""提供商无关的翻译测试数据／随包资源检查；离线，不给译文自动打分。"""
import hashlib
import json
import re
import unittest
from collections import Counter
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
ALIASES = {'enToZh': 'en-zh', 'zhToEn': 'zh-en'}
SUITES = {
    'probes/translation-cases.json': {'en-zh': 16, 'zh-en': 16},
    'probes/translation-comparison-cases.json': {'en-zh': 10, 'zh-en': 10},
    'probes/translation-language-probes.json': {
        'en-ja': 4, 'ja-en': 4, 'en-ko': 4, 'ko-en': 4, 'en-es': 4, 'es-en': 4},
    'validation/translation-holdout.json': {'en-zh': 100, 'zh-en': 100},
    'validation/translation-short-expressions.json': {'en-zh': 44, 'zh-en': 44},
    'validation/translation-confirm-set.json': {'en-zh': 50, 'zh-en': 50},
    'validation/translation-final-set.json': {'en-zh': 112, 'zh-en': 112},
}


def require(condition, message):
    if not condition:
        raise ValueError(message)


def validate_cases(data, counts):
    rows = data if isinstance(data, list) else data['cases']
    require(isinstance(rows, list), 'cases 必须是数组')
    seen = set()
    actual = Counter()
    for row in rows:
        require(isinstance(row, dict), '用例必须是对象')
        key = row.get('id')
        require(isinstance(key, str) and key.strip() and key not in seen, '用例 ID 为空或重复')
        seen.add(key)
        require(isinstance(row.get('source'), str) and row['source'].strip(), '源文为空')
        direction = ALIASES.get(row.get('direction'), row.get('direction'))
        require(direction in counts, '未知方向')
        actual[direction] += 1
        # 风险集用 review 描述语义，不把它强制转换为唯一参考答案。
        if 'reference' in row:
            require(isinstance(row['reference'], str) and row['reference'].strip(), '参考译文为空')
    require(dict(actual) == counts, f'方向／数量不匹配：{dict(actual)} != {counts}')
    return rows


def validate_expression_rows(text, counts):
    require('CC BY-SA 4.0' in text, '表达表缺少许可声明')
    seen, actual = set(), Counter()
    for line in text.splitlines():
        if not line.strip() or line.startswith('#'):
            continue
        fields = line.split('\t')
        require(len(fields) >= 7, '表达表字段不足')
        direction, source, target = fields[:3]
        require(direction in counts and source.strip() and target.strip(), '表达表方向／源文／目标非法')
        key = direction, source.strip().lower()
        require(key not in seen, '表达表重复键')
        seen.add(key)
        actual[direction] += 1
    require(dict(actual) == counts, '表达表数量与清单不符')


def validate_hashes(root, expected):
    require(isinstance(expected, dict) and bool(expected), '哈希清单为空')
    for name, digest in expected.items():
        path = root / name
        require(path.resolve().is_relative_to(root.resolve()), '哈希清单路径越界')
        require(path.is_file(), f'缺失：{name}')
        require(hashlib.sha256(path.read_bytes()).hexdigest() == digest, f'哈希不匹配：{name}')


def validate_all(root=ROOT):
    frozen = json.loads((root / 'validation/manifest.json').read_text())
    required_files = set(SUITES) | {'validation/translation-holdout.tsv',
                                   'probes/translation-risk-checks.json'}
    require(set(frozen['files']) == required_files, '测试集哈希清单缺项／多项')
    validate_hashes(root, frozen['files'])
    suites, ids = {}, set()
    for name, counts in SUITES.items():
        data = json.loads((root / name).read_text())
        rows = validate_cases(data, counts)
        suite_ids = {r['id'] for r in rows}
        require(not ids.intersection(suite_ids), '跨测试集 ID 冲突')
        ids.update(suite_ids)
        suites[name] = rows
        if name.endswith(('confirm-set.json', 'final-set.json')):
            require(data.get('scoringRules', {}).get('frozenBeforeRun') is True, '审阅规则未冻结')
    final = suites['validation/translation-final-set.json']
    require(Counter(r['direction'] for r in final if r.get('metric') != 'probe') ==
            {'en-zh': 100, 'zh-en': 100}, '最终集应译／保留探针分组不符')
    development_sources = set()
    for name in ('probes/translation-cases.json', 'validation/translation-holdout.json',
                 'validation/translation-short-expressions.json',
                 'validation/translation-confirm-set.json', 'validation/translation-final-set.json'):
        sources = {r['source'].strip().lower() for r in suites[name]}
        if name.endswith(('confirm-set.json', 'final-set.json')):
            require(not sources.intersection(development_sources), '确认／最终集与开发集重叠')
        development_sources.update(sources)
    holdout = json.loads((root / 'validation/translation-holdout.json').read_text())
    require(holdout['sourceSha256'] == frozen['files']['validation/translation-holdout.tsv'],
            '留存集不对应冻结 TSV')
    risks = json.loads((root / 'probes/translation-risk-checks.json').read_text())['cases']
    require(set(risks) == {r['id'] for r in suites['probes/translation-cases.json']},
            '风险审阅索引与用例不对应')
    directory = root / 'resources/translation'
    manifest = json.loads((directory / 'manifest.json').read_text())
    require(set(manifest['files']) == {'expressions.tsv', 'templates.json', 'brands.tsv'},
            '资源哈希清单缺项／多项')
    validate_hashes(directory, manifest['files'])
    validate_hashes(directory, {'review-log.tsv': manifest['review']['logSha256']})
    require('CC BY-SA 4.0' in manifest['license'] and manifest.get('attribution'), '资源许可／署名缺失')
    validate_expression_rows((directory / 'expressions.tsv').read_text(),
                             {d: manifest['counts'][d] for d in ('en-zh', 'zh-en')})
    # 这是测试断言而非第二份运行时保护逻辑；品牌的唯一实现仍在共享核心。
    source = (root / 'shared/GogakuCore/translate/translate_safety.cpp').read_text()
    start = source.index('static const char *kBrands[] = {')
    block = source[start:source.index('};', start)]
    compiled = {s.lower() for s in re.findall(r'"([^"]+)"', block)}
    for line in (directory / 'brands.tsv').read_text().splitlines():
        if not line.strip() or line.startswith('#'):
            continue
        fields = line.split('\t')
        require(len(fields) >= 2, '品牌表字段不足')
        if fields[1].strip() == 'preserve' and ' ' not in fields[0].strip():
            require(fields[0].strip().lower() in compiled, '品牌保留表与共享核心不一致')
    return sum(len(rows) for rows in suites.values())


class TranslationDataTests(unittest.TestCase):
    def test_current_data(self):
        self.assertEqual(validate_all(), 688)

    def test_truncated_or_imbalanced_data_rejected(self):
        sample = [{'id': 'a', 'source': 'hello', 'direction': 'en-zh'}]
        self.assertRaises(ValueError, validate_cases, sample, {'en-zh': 2})
        self.assertRaises(ValueError, validate_cases, sample, {'zh-en': 1})

    def test_duplicate_ids_rejected(self):
        row = {'id': 'a', 'source': 'hello', 'direction': 'en-zh'}
        self.assertRaises(ValueError, validate_cases, [row, dict(row)], {'en-zh': 2})

    def test_empty_source_rejected(self):
        self.assertRaises(ValueError, validate_cases,
                          [{'id': 'a', 'source': ' ', 'direction': 'en-zh'}], {'en-zh': 1})

    def test_direction_alias_preserved(self):
        self.assertEqual(len(validate_cases(
            [{'id': 'a', 'source': 'hello', 'direction': 'enToZh'}], {'en-zh': 1})), 1)

    def test_expression_duplicates_rejected(self):
        row = 'en-zh\thello\t你好\t1\thead\the\treviewed\n'
        self.assertRaises(ValueError, validate_expression_rows,
                          '# CC BY-SA 4.0\n' + row + row, {'en-zh': 2})

    def test_expression_license_and_fields_required(self):
        self.assertRaises(ValueError, validate_expression_rows, 'en-zh\ta\tb', {'en-zh': 1})
        self.assertRaises(ValueError, validate_expression_rows, '# CC BY-SA 4.0\nen-zh\ta\tb', {'en-zh': 1})

    def test_hash_mismatch_missing_and_escape_rejected(self):
        import tempfile
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / 'data').write_text('actual')
            self.assertRaises(ValueError, validate_hashes, root, {'data': '0' * 64})
            self.assertRaises(ValueError, validate_hashes, root, {'missing': '0' * 64})
            self.assertRaises(ValueError, validate_hashes, root, {'../outside': '0' * 64})
            self.assertRaises(ValueError, validate_hashes, root, {})


if __name__ == '__main__':
    unittest.main(verbosity=2)
