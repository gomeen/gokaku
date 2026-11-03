#!/usr/bin/env python3
"""翻译策略编排（隔离实验层）：审核资源 → 模板 → 候选生成 → 反向评分 → 结构检查。

本模块是评测辅助进程的一部分，不接入生产 C ABI、不改变输入法行为：

  resource/template/brand  完整输入精确命中时直接给出审核译法，不调用模型
  small100                 短表达 beam=2/2 候选，短句 beam=5/3 候选（按输入宽度分桶）
  quickmt                  只做反向评分（候选→原文），不自由生成回译
  hardening                共享 C++ 加固层（重复/时间/脚本/长度）＋审阅品牌表

排序：正向归一化分数 + λ × 反向归一化分数。λ=0 表示该方向禁用评分调用。
"""
import ctypes
import hashlib
import json
import re
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
RESOURCE_DIR = ROOT / 'resources/translation'
BUDGETS = {'short-expression': 500.0, 'short-sentence': 2000.0}
DEFAULT_LAMBDA = {'en-zh': 0.0, 'zh-en': 0.0}
MAX_INPUT_CHARS = 200

DIRECTION_ALIASES = {'enToZh': 'en-zh', 'zhToEn': 'zh-en'}


def normalize_direction(value):
    return DIRECTION_ALIASES.get(value, value)


def sha256(path):
    digest = hashlib.sha256()
    with Path(path).open('rb') as handle:
        for chunk in iter(lambda: handle.read(1 << 20), b''):
            digest.update(chunk)
    return digest.hexdigest()


def input_width(source):
    cjk = sum(1 for ch in source if '\u4e00' <= ch <= '\u9fff')
    words = len([w for w in re.split(r'\s+', source) if w])
    return cjk + words


def timing_bucket(source):
    return 'short-expression' if input_width(source) <= 8 else 'short-sentence'


def normalize_source(text):
    text = (text or '').strip()
    text = text.strip('"\'“”‘’')
    text = re.sub(r'\s+', ' ', text)
    text = text.rstrip('。．.!！?？,，;；:：')
    if re.fullmatch(r'[\x00-\x7f ]*', text):
        text = text.lower()
    return text


def decode_number_words(text):
    words = {
        'one': 1, 'two': 2, 'three': 3, 'four': 4, 'five': 5, 'six': 6, 'seven': 7,
        'eight': 8, 'nine': 9, 'ten': 10, 'eleven': 11, 'twelve': 12,
        'thirteen': 13, 'fourteen': 14, 'fifteen': 15, 'sixteen': 16,
        'seventeen': 17, 'eighteen': 18, 'nineteen': 19, 'twenty': 20,
    }
    return words.get(text.strip().lower())


CN_DIGITS = {'零': 0, '〇': 0, '一': 1, '二': 2, '两': 2, '三': 3, '四': 4,
             '五': 5, '六': 6, '七': 7, '八': 8, '九': 9}


def cn_number(text):
    """解析 0–59 的中文数字（三、十、十一、二十三、二十）。"""
    if not text:
        return None
    if text.isdigit():
        return int(text)
    if '十' in text:
        head, _, tail = text.partition('十')
        tens = CN_DIGITS.get(head, 1) if head else 1
        ones = CN_DIGITS.get(tail, 0) if tail else 0
        return tens * 10 + ones
    if len(text) == 1 and text in CN_DIGITS:
        return CN_DIGITS[text]
    return None


class Resources:
    """审核过的表达资源：只做完整输入精确命中。"""

    def __init__(self, directory=RESOURCE_DIR):
        self.directory = Path(directory)
        manifest_path = self.directory / 'manifest.json'
        if not manifest_path.is_file():
            raise RuntimeError('translation resource manifest missing: %s' % manifest_path)
        self.manifest = json.loads(manifest_path.read_text(encoding='utf-8'))
        path = self.directory / 'expressions.tsv'
        actual = sha256(path)
        expected = self.manifest.get('files', {}).get('expressions.tsv')
        if expected and actual != expected:
            raise RuntimeError('expressions.tsv hash mismatch: %s != %s' % (actual, expected))
        self.sha256 = actual
        self.version = self.manifest.get('version')
        self.index = {}
        self.counts = {'en-zh': 0, 'zh-en': 0}
        for line in path.read_text(encoding='utf-8').splitlines():
            if not line.strip() or line.startswith('#'):
                continue
            fields = line.split('\t')
            if len(fields) < 7:
                continue
            direction, source, target, sense_groups, headword, pinyin, status = fields[:7]
            alternates = fields[7].split('|') if len(fields) > 7 and fields[7] else []
            direction = normalize_direction(direction)
            key = (direction, normalize_source(source))
            if key in self.index:
                continue
            self.index[key] = {
                'source': source,
                'target': target,
                'senseGroups': int(sense_groups) if sense_groups.isdigit() else 1,
                'headword': headword,
                'pinyin': pinyin,
                'reviewStatus': status,
                'alternates': [a for a in alternates if a],
                'resourceVersion': self.version,
            }
            self.counts[direction] += 1

    def lookup(self, direction, source):
        return self.index.get((direction, normalize_source(source)))


class Templates:
    """双向时间/日期模板：只有完整输入被覆盖时才给出译法。"""

    def __init__(self, path=RESOURCE_DIR / 'templates.json'):
        self.raw = json.loads(Path(path).read_text(encoding='utf-8'))
        self.version = self.raw['version']
        self.zh_meridiem = self.raw['meridiem']['zh']
        self.en_meridiem = self.raw['meridiem']['en']
        self.zh_output = self.raw['meridiem']['zhOutput']
        self.en_output = self.raw['meridiem']['enOutput']
        self.relative = self.raw['relativeDays']
        self.relative_en = {v.lower(): k for k, v in self.relative.items()}
        self.zh_range = self.raw['rangeJoin']['zh']
        self.en_range = self.raw['rangeJoin']['en']
        self.en_range_prefix = self.raw['enRangePrefix']
        self.minute_forms = self.raw['minuteForms']['zh']

    # ---- 中文 → 英文 ----
    def _parse_zh_time(self, text):
        """返回 (params, rest)，params 为 None 表示不是完整时间表达。"""
        original = text
        relative = None
        for word in sorted(self.relative, key=len, reverse=True):
            if text.startswith(word):
                relative = word
                text = text[len(word):]
                break
        meridiem = None
        for word in sorted(self.zh_meridiem, key=len, reverse=True):
            if text.startswith(word):
                meridiem = self.zh_meridiem[word]
                text = text[len(word):]
                break
        if text.startswith('在'):
            text = text[1:]
        match = re.match(r'^([0-9]{1,2}|[零〇一二两三四五六七八九十]{1,3})\s*[点时:：]', text)
        if not match:
            return None, original
        hour = cn_number(match.group(1))
        if hour is None or hour > 24:
            return None, original
        rest = text[match.end():]
        minute = None
        half = False
        for form, value in self.minute_forms.items():
            if rest.startswith(form):
                minute = value
                half = value == 30
                rest = rest[len(form):]
                break
        else:
            number = re.match(r'^([0-9]{1,2}|[零〇一二两三四五六七八九十]{1,3})(?:分)?', rest)
            if number and (rest.startswith('整') or number.group(0).endswith('分')):
                minute = cn_number(number.group(1))
                rest = rest[len(number.group(0)):]
            if rest.startswith('整'):
                minute = 0
                rest = rest[1:]
        if rest.startswith('钟'):
            rest = rest[1:]
        return ({'relative': relative, 'meridiem': meridiem, 'hour': hour,
                 'minute': minute, 'half': half}, rest)

    def _render_en_time(self, params):
        hour = params['hour']
        minute = params['minute']
        meridiem = params['meridiem']
        if meridiem is None:
            clock = ('%d o\'clock' % hour) if minute in (None, 0) else '%d:%02d' % (hour, minute)
        else:
            clock = '%d %s' % (hour, self.en_output[meridiem])
            if minute not in (None, 0):
                clock = '%d:%02d %s' % (hour, minute, self.en_output[meridiem])
        if params['relative']:
            clock = '%s %s' % (clock, self.relative[params['relative']])
        return clock

    def _match_zh(self, source):
        text = normalize_source(source)
        first, rest = self._parse_zh_time(text)
        if first is None:
            return None
        for joiner in sorted(self.zh_range, key=len, reverse=True):
            if rest.startswith(joiner):
                second, tail = self._parse_zh_time(rest[len(joiner):])
                if second is not None and not tail:
                    return {
                        'target': 'from %s to %s' % (self._render_en_time(first),
                                                     self._render_en_time(second)),
                        'params': {'range': [first, second]},
                    }
                break
        if rest:
            return None
        return {'target': self._render_en_time(first), 'params': first}

    # ---- 英文 → 中文 ----
    def _parse_en_time(self, text):
        original = text
        relative = None
        for word in sorted(self.relative_en, key=len, reverse=True):
            if text.lower().startswith(word):
                relative = self.relative_en[word]
                text = text[len(word):].strip()
                break
        if text.lower().startswith('at '):
            text = text[3:].strip()
        match = re.match(r'^(\d{1,2})(?::(\d{2}))?\s*(a\.m\.|p\.m\.|am|pm|morning|afternoon|evening)?',
                         text, re.IGNORECASE)
        if not match:
            return None, original
        hour = int(match.group(1))
        if hour > 24:
            return None, original
        minute = int(match.group(2)) if match.group(2) else None
        meridiem = None
        if match.group(3):
            meridiem = self.en_meridiem.get(match.group(3).lower())
        rest = text[match.end():].strip()
        if rest.startswith("o'clock"):
            rest = rest[len("o'clock"):].strip()
        if not relative and rest:
            lowered = rest.lower()
            for word in sorted(self.relative_en, key=len, reverse=True):
                if lowered == word:
                    relative = self.relative_en[word]
                    rest = ''
                    break
        return ({'relative': relative, 'meridiem': meridiem, 'hour': hour,
                 'minute': minute, 'half': minute == 30}, rest)

    def _render_zh_time(self, params):
        head = ''
        if params['relative']:
            head += params['relative']
        if params['meridiem']:
            head += self.zh_output[params['meridiem']]
        clock = '%d点' % params['hour']
        if params['minute'] == 30:
            clock += '半'
        elif params['minute'] == 15:
            clock += '一刻'
        elif params['minute'] == 45:
            clock += '三刻'
        elif params['minute'] not in (None, 0):
            clock += '%d分' % params['minute']
        return head + clock

    def _match_en(self, source):
        text = normalize_source(source)
        prefix = ''
        for candidate in self.en_range_prefix:
            if text.lower().startswith(candidate):
                prefix = candidate
                text = text[len(candidate):].strip()
                break
        first, rest = self._parse_en_time(text)
        if first is None:
            return None
        for joiner in self.en_range:
            stripped = rest
            if stripped.lower().startswith(joiner.strip()) and stripped:
                tail_text = stripped[len(joiner.strip()):].strip()
                second, tail = self._parse_en_time(tail_text)
                if second is not None and not tail:
                    target = self._render_zh_time(first) + '到' + self._render_zh_time(second)
                    return {'target': target, 'params': {'range': [first, second]}}
        if rest or prefix:
            if rest and not prefix:
                return None
        if not rest:
            return {'target': self._render_zh_time(first), 'params': first}
        return None

    def match(self, direction, source):
        direction = normalize_direction(direction)
        found = self._match_zh(source) if direction == 'zh-en' else self._match_en(source)
        if not found:
            return None
        found['templateVersion'] = self.version
        return found


class Brands:
    """审阅过的品牌/产品名处理表。"""

    def __init__(self, path=RESOURCE_DIR / 'brands.tsv'):
        self.preserve = []
        self.maps = {}
        self.version = 'audited-v1'
        for line in Path(path).read_text(encoding='utf-8').splitlines():
            if not line.strip() or line.startswith('#'):
                continue
            fields = line.split('\t')
            if len(fields) < 3:
                continue
            term, policy, canonical = fields[0].strip(), fields[1].strip(), fields[2].strip()
            if policy == 'preserve':
                self.preserve.append((term, canonical))
            elif policy == 'map':
                self.maps[term.lower()] = canonical

    def exact_map(self, source):
        return self.maps.get(normalize_source(source).lower())

    def required(self, source):
        """输入里出现、且候选译文必须原样保留的词条。"""
        lowered = source.lower()
        out = []
        for term, canonical in self.preserve:
            if re.search(r'(?<![A-Za-z0-9])' + re.escape(term.lower()) + r'(?![A-Za-z0-9])',
                         lowered):
                out.append((term, canonical))
        return out

    def satisfies(self, output, required):
        lowered = (output or '').lower()
        missing = []
        for term, canonical in required:
            if term.lower() not in lowered and canonical.lower() not in lowered:
                missing.append(term)
        return missing


class Structure:
    """共享 C++ 加固层（只做它确实能识别的检查）。"""

    def __init__(self, dylib):
        path = Path(dylib)
        if not path.is_file():
            raise RuntimeError('hardening dylib missing: %s (build .build/core first)' % path)
        lib = ctypes.CDLL(str(path))
        lib.gc_translate_repeat_classify.argtypes = [ctypes.c_char_p, ctypes.c_size_t]
        lib.gc_translate_repeat_classify.restype = ctypes.c_int32
        lib.gc_translate_t2s.argtypes = [ctypes.c_char_p, ctypes.c_size_t, ctypes.c_char_p,
                                         ctypes.c_size_t]
        lib.gc_translate_t2s.restype = ctypes.c_size_t
        lib.gc_translate_has_traditional.argtypes = [ctypes.c_char_p, ctypes.c_size_t]
        lib.gc_translate_has_traditional.restype = ctypes.c_int32
        lib.gc_translate_time_check.argtypes = [ctypes.c_char_p, ctypes.c_size_t,
                                                ctypes.c_char_p, ctypes.c_size_t]
        lib.gc_translate_time_check.restype = ctypes.c_int32
        lib.gc_translate_script_check.argtypes = [ctypes.c_char_p, ctypes.c_size_t, ctypes.c_char]
        lib.gc_translate_script_check.restype = ctypes.c_int32
        lib.gc_translate_length_check.argtypes = [ctypes.c_char_p, ctypes.c_size_t,
                                                  ctypes.c_char_p, ctypes.c_size_t]
        lib.gc_translate_length_check.restype = ctypes.c_int32
        lib.gc_translate_protection_scan.argtypes = [ctypes.c_char_p, ctypes.c_size_t, ctypes.c_void_p,
                                                     ctypes.c_size_t]
        lib.gc_translate_protection_scan.restype = ctypes.c_size_t
        self.lib = lib

    def t2s(self, text):
        raw = text.encode('utf-8')
        needed = self.lib.gc_translate_t2s(raw, len(raw), None, 0)
        buffer = ctypes.create_string_buffer(needed)
        self.lib.gc_translate_t2s(raw, len(raw), buffer, needed)
        return buffer.value.decode('utf-8')

    def check(self, source, output, direction, required_brands):
        """对一个候选做结构检查。返回 {accepted, reason, verdict, normalized}。"""
        text = (output or '').strip()
        if not text:
            return {'accepted': False, 'reason': 'empty', 'verdict': 'empty'}
        raw = text.encode('utf-8')
        src = source.encode('utf-8')
        repeat = int(self.lib.gc_translate_repeat_classify(raw, len(raw)))
        time = int(self.lib.gc_translate_time_check(src, len(src), raw, len(raw)))
        length = int(self.lib.gc_translate_length_check(src, len(src), raw, len(raw)))
        expected_script = b'Z' if direction == 'en-zh' else b'E'
        script = int(self.lib.gc_translate_script_check(raw, len(raw), expected_script))
        traditional = int(self.lib.gc_translate_has_traditional(raw, len(raw)))
        evidence = {'repeat': repeat, 'time': time, 'length': length, 'script': script,
                    'traditional': traditional, 'normalized': None}
        if repeat >= 1:
            return {'accepted': False, 'reason': 'repeat', 'verdict': 'reject', **evidence}
        if time in (1, 2, 3, 4):
            return {'accepted': False, 'reason': 'time-%d' % time, 'verdict': 'reject', **evidence}
        if length in (1, 2):
            return {'accepted': False, 'reason': 'length-%d' % length, 'verdict': 'reject',
                    **evidence}
        if script != 0:
            if traditional:
                normalized = self.t2s(text)
                nraw = normalized.encode('utf-8')
                if int(self.lib.gc_translate_script_check(nraw, len(nraw), expected_script)) == 0 and \
                        int(self.lib.gc_translate_repeat_classify(nraw, len(nraw))) == 0:
                    text = normalized
                    evidence['normalized'] = normalized
                    evidence['verdict'] = 'candidate-normalized'
                else:
                    return {'accepted': False, 'reason': 'script', 'verdict': 'reject', **evidence}
            else:
                return {'accepted': False, 'reason': 'script', 'verdict': 'reject', **evidence}
        else:
            evidence['verdict'] = 'candidate'
        missing = self.brands_satisfied(text, required_brands)
        if missing:
            evidence['missingBrands'] = missing
            return {'accepted': False, 'reason': 'brand', 'verdict': 'reject', **evidence}
        evidence['accepted'] = True
        evidence['reason'] = None
        evidence['text'] = text
        return evidence

    @staticmethod
    def brands_satisfied(output, required):
        lowered = (output or '').lower()
        return [term for term, canonical in required
                if term.lower() not in lowered and canonical.lower() not in lowered]


class PreserveDetector:
    """运行时识别「应该原样保留」的输入（不读测试标签）。"""

    def __init__(self, english_words=ROOT / 'resources/english-words.txt'):
        self.words = {w.strip().lower() for w in english_words.read_text(encoding='utf-8').splitlines()
                      if w.strip()}
        self.words |= {'ok', 'hi', 'thanks', 'bye', 'yes', 'no'}

    def reason(self, source):
        text = (source or '').strip()
        if not text:
            return 'empty'
        if len(text) > MAX_INPUT_CHARS:
            return 'over-length'
        if not re.search(r'[A-Za-z\u4e00-\u9fff]', text):
            return 'no-letters'
        if re.fullmatch(r'[A-Za-z]+', text):
            lowered = text.lower()
            if len(text) < 2:
                return 'single-letter'
            if lowered not in self.words:
                return 'unknown-word'
        if re.fullmatch(r'(https?://|www\.)\S+', text):
            return 'url-only'
        if re.fullmatch(r'v?\d+(\.\d+)+', text, re.IGNORECASE):
            return 'version-only'
        return None


class Pipeline:
    """一条固定路线：资源 → 模板 → 品牌 → 模型候选 → 反向评分 → 结构检查。"""

    def __init__(self, resources, templates, brands, structure, generate, score,
                 lambdas=None, preserve=None, score_always=False, beams=None):
        self.resources = resources
        self.templates = templates
        self.brands = brands
        self.structure = structure
        self.generate = generate      # (case) -> (worker_row, ms)
        self.score = score            # (case) -> (scores, ms) or (None, 0.0)
        self.lambdas = dict(DEFAULT_LAMBDA)
        if lambdas:
            self.lambdas.update(lambdas)
        self.preserve = preserve or PreserveDetector()
        # 开发数据采集：λ=0 也要取反向分数，供离线选 λ（不重复推理）。
        self.score_always = score_always
        # 解码分桶：{桶: (beam, 候选数)}；默认短表达 2/2、短句 5/3。
        self.beams = {'short-expression': (2, 2), 'short-sentence': (5, 3)}
        if beams:
            self.beams.update({k: tuple(v) for k, v in beams.items()})

    def _direct(self, direction, source, target, kind, extra=None):
        required = self.brands.required(source)
        evidence = self.structure.check(source, target, direction, required)
        result = {
            'action': 'candidate' if evidence['accepted'] else 'fallback-original',
            'text': evidence.get('text', target) if evidence['accepted'] else source,
            'path': kind,
            'reason': evidence.get('reason'),
            'candidates': [{'text': target, 'path': kind, 'accepted': evidence['accepted'],
                            'reason': evidence.get('reason'), 'checks': evidence,
                            'forwardScore': None, 'reverseScore': None, 'rankScore': None,
                            'ended': True, 'truncated': False}],
        }
        if extra:
            result.update(extra)
        return result

    def translate(self, case):
        direction = normalize_direction(case.get('direction'))
        source = case.get('source', '')
        bucket = timing_bucket(source)
        result = {
            'id': case.get('id'),
            'direction': direction,
            'source': source,
            'timingBucket': bucket,
            'preserveReason': None,
            'candidates': [],
            'lambda': self.lambdas.get(direction, 0.0),
            'path': None,
            'action': None,
            'text': None,
            'reason': None,
            'stageMs': {'lookup': 0.0, 'generate': 0.0, 'check': 0.0, 'score': 0.0,
                        'total': 0.0},
        }
        start_ns = time.perf_counter_ns()

        def stage(name, since_ns):
            result['stageMs'][name] = (time.perf_counter_ns() - since_ns) / 1e6

        # 0) 运行时保留判定（错误拼写/代码/超长等）
        reason = self.preserve.reason(source)
        if reason:
            result['preserveReason'] = reason
            result.update({'action': 'preserve', 'text': source, 'path': 'runtime-preserve',
                           'reason': reason, 'candidates': []})
            stage('total', start_ns)
            return result

        # 1) 品牌规范映射（完整输入）
        mapped = self.brands.exact_map(source)
        if mapped:
            result.update(self._direct(direction, source, mapped, 'brand-map'))
            stage('total', start_ns)
            return result

        look_start = time.perf_counter_ns()
        # 2) 审核表达资源（完整输入精确命中）
        entry = self.resources.lookup(direction, source)
        if entry:
            result.update(self._direct(
                direction, source, entry['target'], 'resource',
                {'resource': entry}))
            stage('lookup', look_start)
            stage('total', start_ns)
            return result
        # 3) 双向时间/日期模板（完整输入）
        template = self.templates.match(direction, source)
        if template:
            result.update(self._direct(
                direction, source, template['target'], 'template',
                {'template': {'version': template['templateVersion'],
                              'params': template['params']}}))
            stage('lookup', look_start)
            stage('total', start_ns)
            return result
        stage('lookup', look_start)

        # 4) 模型候选
        beam, num = self.beams[bucket]
        request = {'id': case.get('id'), 'direction': direction, 'source': source,
                   'kind': case.get('kind'), 'beam': beam, 'numHypotheses': num}
        gen_ns = time.perf_counter_ns()
        row, gen_ms = self.generate(request)
        stage('generate', gen_ns)
        result['generate'] = {
            'beam': row.get('beam', beam), 'numHypotheses': row.get('numHypotheses', num),
            'ipcMs': gen_ms, 'error': row.get('error'),
            'modelMs': row.get('totalMs'),
        }
        if row.get('error'):
            result.update({'action': 'fallback-original', 'text': source, 'path': 'model-error',
                           'reason': 'worker-error', 'candidates': []})
            stage('total', start_ns)
            return result

        required = self.brands.required(source)
        candidates = []
        seen = set()
        check_ns = time.perf_counter_ns()
        for candidate in row.get('candidates') or []:
            text = (candidate.get('text') or '').strip()
            evidence = self.structure.check(source, text, direction, required)
            # 繁体漂移归一后的文本才是要上屏的候选，重复判定按归一后文本。
            text = evidence.get('text') or text
            key = re.sub(r'\s+', '', text)
            if not key or key in seen:
                continue
            seen.add(key)
            entry_row = {
                'text': text,
                'ended': candidate.get('ended'),
                'truncated': candidate.get('truncated'),
                'forwardScore': candidate.get('score'),
                'tokens': candidate.get('tokens'),
                'accepted': evidence['accepted'],
                'reason': evidence.get('reason'),
                'checks': evidence,
                'reverseScore': None,
                'reverseTokens': None,
                'rankScore': None,
            }
            if candidate.get('truncated') and evidence['accepted']:
                # 达到解码上限而未正常结束：失去提交资格（不裁尾冒充完整译文）
                entry_row['accepted'] = False
                entry_row['reason'] = 'no-end-token'
            candidates.append(entry_row)
        stage('check', check_ns)

        survivors = [c for c in candidates if c['accepted']]
        lam = self.lambdas.get(direction, 0.0)
        if survivors and (lam > 0 or self.score_always):
            score_ns = time.perf_counter_ns()
            scores, score_ipc = self.score({'id': case.get('id'), 'direction': direction,
                                            'source': source,
                                            'candidates': [c['text'] for c in survivors]})
            stage('score', score_ns)
            result['scoreRequest'] = {'ipcMs': score_ipc, 'count': len(survivors)}
            if scores:
                for candidate, score in zip(survivors, scores):
                    candidate['reverseScore'] = score.get('normalized')
                    candidate['reverseLogProb'] = score.get('logProb')
                    candidate['reverseTokens'] = score.get('tokens')
        for candidate in survivors:
            forward = candidate.get('forwardScore') or 0.0
            reverse = candidate.get('reverseScore') or 0.0
            candidate['forwardScore'] = forward
            candidate['rankScore'] = forward + lam * reverse

        result['candidates'] = sorted(
            candidates,
            key=lambda c: (0 if c['accepted'] else 1,
                           -(c['rankScore'] if c['rankScore'] is not None else
                             (c['forwardScore'] or 0.0))),
        )
        if survivors:
            best = max(survivors, key=lambda c: (c['rankScore'], c['forwardScore']))
            result.update({'action': 'candidate', 'text': best['text'], 'path': 'model',
                           'reason': None})
        else:
            result.update({'action': 'fallback-original', 'text': source,
                           'path': 'structural-reject',
                           'reason': ','.join(sorted({c.get('reason') or 'unknown'
                                                      for c in candidates})) or 'no-candidates'})
        stage('total', start_ns)
        return result
