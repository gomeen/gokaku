#!/usr/bin/env python3
"""Gogaku 立即输入（首键）回归驱动：5 种确认方式 × 4 种后键 × N 次。

目标
----
确认键之后紧跟的后键必须被完整、唯一、按序地处理：不多字、不少字、不乱序。
本驱动按「严格立即输入矩阵」执行：

  5 种确认方式：空格 / Enter / 数字 1 / 组合中分号 / 组合中 Shift
  4 种后键：    字母 n / 逗号 / 句号 / 停止（不发任何键）
  每组 N 次（默认 200），确认与后键之间没有人为延迟（同一进程内背靠背投递）。

安全约束
--------
1. 只操作本次运行创建的专属窗口／文档／PTY，绝不关闭或改动用户的既有文档。
2. 每次投递按键前都强断言「前台应用身份」与「专属测试目标身份」：
   前台 bundle 与 pid 必须与预期一致；前台窗口标题必须含本轮唯一标记
   （浏览器用页面标题里的运行标记；Orca 用本轮独占的 PTY 文件与终端句柄）。
   断言失败即停止整轮运行，不做任何补发或重试。
3. 断言一律精确相等（正文逐字比对），不做「包含／计数」式宽松判定，
   失败不重试、不掩盖：失败即记录证据并让进程以非零码退出。

候选窗状态协议（ValidationMonitor，验收构建）
--------------------------------------------
传输：AF_UNIX / SOCK_STREAM；默认路径 ~/Library/Logs/Gogaku/validation.sock
      （目录 0700，socket 0600，仅当前用户）。
启用：需要 ~/Library/Logs/Gogaku/validation-enabled（0600，当前用户所有）
      且输入源进程以验收构建重启；--enable-validation 会创建开关并重启输入法。
命令：单行 ASCII 命令加换行。
      state\\n    → {"visible","generation","hideCount","staleRenderCount",
                      "confirmationCount","confirmationHideFailures","events"}
      metrics\\n  → 同上再加 "samples"（逐事件耗时数组，不含文字）
      reset\\n    → 清空样本与计数
字段含义：
      visible                候选窗内容当前是否可见
      generation             候选窗代次（每次入队渲染或隐藏递增）
      hideCount              累计隐藏次数
      staleRenderCount       已被更新代次作废的渲染次数
      confirmationCount      累计插字（insertText）次数；逗号／句号后键在无组合
                             状态走标点表也计一次——不能把每轮笼统算成一次提交
      confirmationHideFailures 插字时候选窗仍未在回调内隐藏的次数（必须为 0）
      events                 已记录的事件样本数
样本字段（无文字）：callbackNs/coreNs/queueWaitNs/coreExecNs/hostReadNs/
      markedWriteNs/anchorReadNs/commitCallNs/renderNs/firstDisplayNs/consumed/
      visibleAtReturn/confirmationHidden/commitCount（事件内插字次数）/
      hostSelection（选区数值）/scenario（场景标识）。
判定要点：
      * 「回调内隐藏」以 confirmationHideFailures 与样本里的 confirmationHidden
        为准，不靠事后轮询推断。
      * 插字次数按「确认事件」与「后键」分别核算：逗号／句号后键每轮两次插字
        （正文确认＋标点插入），漏字偏小、重复偏大都判失败（合成回归验证，
        --self-test）。
      * 光标：宿主可读真实选区时用实际值（探针／TextEdit／浏览器 AX）；
        Terminal 无选区可读，用「移动光标后插入固定字符并核对全文」的行为学
        核对；PTY 连选区语义都没有，明确记未验证，不用字符串长度冒充光标。
      * 后键字母会开启新组合（新候选窗），不得当成旧窗重弹；需要「2 秒未重弹」
        的场景是停止输入确认，后键组合先清理再观察。

用法
----
    # 只生成场景计划，不发任何事件（可离线执行）
    python3 probes/first_key_regression.py --plan-only --plan-out /tmp/gogaku-first-key-plan.json
    python3 probes/first_key_regression.py --self-test

    # 真实回归（会接管前台并发送按键）
    python3 probes/first_key_regression.py --hosts textedit,chrome --iterations 200 \
        --panel-state-socket "$HOME/Library/Logs/Gogaku/validation.sock"
"""
import argparse
import hashlib
import json
import os
from datetime import datetime, timezone
from pathlib import Path
import plistlib
import select
import shutil
import socket
import statistics
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parent.parent
ENV = dict(os.environ)
if Path('/Applications/Xcode.app/Contents/Developer').is_dir():
    ENV.setdefault('DEVELOPER_DIR', '/Applications/Xcode.app/Contents/Developer')
SOURCE = os.environ.get('GOGAKU_SOURCE', 'org.gogaku.inputmethod.Hans')
INSTALLED_BINARY = Path.home() / 'Library/Input Methods/Gogaku.app/Contents/MacOS/GogakuInput'
PROBE_BUNDLE_ID = 'org.gogaku.validation.host'
LOG_DIR = Path.home() / 'Library/Logs/Gogaku'
DEFAULT_SOCKET = LOG_DIR / 'validation.sock'
VALIDATION_MARKER = LOG_DIR / 'validation-enabled'
SETTINGS_PATH = Path.home() / 'Library/Application Support/Gogaku/settings.json'

# 组合输入：小鹤双拼 nihc → 你好
COMPOSITION = 'nihc'
COMPOSITION_LETTERS = list(COMPOSITION)

# 5 种确认方式。committed 是「确认之后宿主正文应精确等于」的字符串。
CONFIRMATIONS = [
    {'id': 'space', 'label': '空格确认首选候选',
     'steps': [[{'key': 'space'}]], 'committed': '你好'},
    {'id': 'enter', 'label': 'Enter 上屏原编码',
     'steps': [[{'key': 'return'}]], 'committed': 'nihc'},
    {'id': 'digit1', 'label': '数字 1 选当前页首个候选',
     'steps': [[{'key': '1'}]], 'committed': '你好'},
    {'id': 'semicolon', 'label': '组合中分号一次上屏',
     'steps': [[{'key': ';'}]], 'committed': '你好；'},
    {'id': 'shift', 'label': '组合中 Shift 单击上屏原编码',
     'steps': [[{'modifier': 'shift', 'hold': 0.05}]], 'committed': 'nihc'},
]

# 4 种后键。kind 决定期望结果：punctuation 追加标点，composition 起新组合，cancel 不留残留。
POST_KEYS = [
    {'id': 'letter', 'label': '字母 n（后键首字）', 'kind': 'composition',
     'steps': [[{'key': 'n'}]], 'marked': 'n', 'panel': True},
    {'id': 'comma', 'label': '逗号（无组合标点表）', 'kind': 'punctuation',
     'steps': [[{'key': ','}]], 'committed': '，', 'panel': False},
    {'id': 'period', 'label': '句号（无组合标点表）', 'kind': 'punctuation',
     'steps': [[{'key': '.'}]], 'committed': '。', 'panel': False},
    {'id': 'stop', 'label': '停止（不发任何键）', 'kind': 'stop',
     'steps': [], 'panel': False},
]

HOST_ORDER = ['textedit', 'chrome', 'safari', 'terminal', 'orca-pty', 'probe']
TARGETS = {
    'textedit': ['default'],
    'chrome': ['textarea', 'contenteditable'],
    'safari': ['textarea', 'contenteditable'],
    'terminal': ['default'],
    'orca-pty': ['default'],
    'probe': ['default'],
}


class GuardError(RuntimeError):
    """前台身份或专属目标身份断言失败：禁止继续投递按键。"""


class HostError(RuntimeError):
    """宿主读取／准备失败。"""


class PanelStateError(RuntimeError):
    """候选窗状态 socket 不可用或响应不合法。"""


def now_iso():
    return datetime.now(timezone.utc).isoformat()


def sha256_file(path):
    try:
        return hashlib.sha256(Path(path).read_bytes()).hexdigest()
    except OSError:
        return None


def sha256_text(text):
    return hashlib.sha256(text.encode('utf-8')).hexdigest()


def osa(script, timeout=25):
    """AppleScript 执行；失败抛 HostError（不回退到宽松判定）。"""
    result = subprocess.run(['osascript', '-'], input=script, text=True,
                            capture_output=True, timeout=timeout, env=ENV)
    if result.returncode != 0:
        raise HostError(f'osascript 失败：{result.stderr.strip()[:200]}')
    return result.stdout.strip()


def enable_validation_monitor():
    """创建私有开关并重启输入法进程（验收构建的 socket 才存在）。"""
    LOG_DIR.mkdir(parents=True, exist_ok=True)
    os.chmod(LOG_DIR, 0o700)
    VALIDATION_MARKER.write_text('')
    os.chmod(VALIDATION_MARKER, 0o600)
    subprocess.run(['pkill', '-x', 'GogakuInput'], capture_output=True)
    return str(VALIDATION_MARKER)


def input_letters_enabled():
    """读取设置里的「输入区字母」开关；关掉时宿主看不到 marked text，期望要改。"""
    try:
        data = json.loads(SETTINGS_PATH.read_text())
    except (OSError, json.JSONDecodeError):
        return True
    value = data.get('inputLettersEnabled')
    return True if value is None else bool(value)


def read_settings():
    try:
        return json.loads(SETTINGS_PATH.read_text())
    except (OSError, json.JSONDecodeError):
        return {}


def write_settings(update, notify_binary):
    """写入测试设置并热更新输入法（Distributed Notification）；返回原值供恢复。
    设置解析对缺失字段用默认值，部分写入安全；不碰用户其他偏好。"""
    data = read_settings()
    original = {key: data.get(key) for key in update}
    data.update(update)
    SETTINGS_PATH.parent.mkdir(parents=True, exist_ok=True)
    temporary = SETTINGS_PATH.with_suffix('.json.tmp')
    temporary.write_text(json.dumps(data, ensure_ascii=False, indent=2) + '\n')
    os.replace(temporary, SETTINGS_PATH)
    subprocess.run([str(notify_binary), 'org.gogaku.settings.changed'],
                   check=True, env=ENV)
    time.sleep(0.6)
    return original


# --------------------------------------------------------------------------
# 场景模型：期望结果、计划生成、计划自检
# --------------------------------------------------------------------------

def expected_result(confirm, post, value_view='committed_only'):
    """返回一次迭代的精确期望。

    committed：确认＋后键之后宿主正文应精确等于的字符串。
    marked：   组合中的输入区字母（仅 value_view='marked_visible' 的宿主可见）。
    value：    宿主可观测文本的精确期望。
    caret：    光标（插入点）应处的位置。
    panel：    候选窗此后的可见性期望（True=应可见）。
    """
    committed = confirm['committed']
    marked = ''
    if post['kind'] == 'punctuation':
        committed = committed + post['committed']
    elif post['kind'] == 'composition':
        marked = post['marked']
    visible_marked = marked if value_view == 'marked_visible' else ''
    value = committed + visible_marked
    if post['kind'] == 'composition':
        caret = len(committed) + len(visible_marked)
    else:
        caret = len(committed)
    return {'committed': committed, 'marked': marked, 'value': value,
            'caret': caret, 'panel': bool(post['panel'])}


# --------------------------------------------------------------------------
# 插字次数核算：确认事件与后键分别计数，不能把每轮都算成一次提交
# --------------------------------------------------------------------------

def expected_insert_events(confirm, post):
    """一次迭代的插字次数期望（按事件路径，与宿主文本无关）。

    确认事件本身插字 1 次（空格／Enter／数字／组合中标点，或 Shift 单击的
    释放事件）；逗号／句号后键在无组合状态走标点表，再插字 1 次；字母后键
    开新组合只写 marked text，不插字；停止不发键。
    """
    return {
        'confirmEvent': 1,
        'postKeyEvent': 1 if post['kind'] == 'punctuation' else 0,
    }


def expected_iteration_insert_total(confirm, post):
    counts = expected_insert_events(confirm, post)
    return counts['confirmEvent'] + counts['postKeyEvent']


EVENT_KEY_DOWN = 10
EVENT_FLAGS_CHANGED = 12


def commit_count(sample):
    """事件内插字次数；旧构建无 commitCount 时退化为「是否插过字」。"""
    if isinstance(sample.get('commitCount'), int):
        return int(sample['commitCount'])
    return 1 if 'commitCallNs' in sample else 0


def commit_observed(sample):
    return 'commitCallNs' in sample


def verify_insert_delta(confirm, post, delta, label=''):
    """状态计数器口径：本轮迭代的提交计数增量必须恰好等于期望插字次数。
    漏字（偏小）与重复插字（偏大）都判失败。"""
    expected = expected_iteration_insert_total(confirm, post)
    prefix = f'{label}：' if label else ''
    if delta != expected:
        kind = '漏字' if delta < expected else '重复插字'
        return [f'{prefix}插字次数不符（{kind}）：期望 {expected}，实际 {delta}']
    return []


def verify_iteration_samples(confirm, post, block, label=''):
    """样本流口径：一次迭代的事件按序归位，插字只落在确认事件与标点后键。

    block 是本轮迭代内按 id 升序的验收样本：4 个组合字母 keyDown → 确认事件
    （keyDown；Shift 为按下＋释放两个 flagsChanged，插字在释放事件）→ 后键
    （停止：无；逗号／句号／字母：1 个 keyDown）→ 字母后键的续输 keyDown。
    每个带插字的事件必须 confirmationHidden=true 且事件结束时 visibleAtReturn=false。
    结构对不上时返回 (problems, aligned=False)：计数判定交给计数器，这里
    不断言对齐，但也不把对不上的轮次当成通过。
    """
    problems = []
    aligned = True
    prefix = f'{label}：' if label else ''
    pos = 0

    def take(expected_type, what):
        nonlocal pos, aligned
        if pos >= len(block) or block[pos].get('type') != expected_type:
            actual = block[pos].get('type') if pos < len(block) else '缺失'
            problems.append(f'{prefix}{what}事件缺失或类型不符（期望 {expected_type}，'
                            f'实际 {actual}）')
            aligned = False
            return None
        sample = block[pos]
        pos += 1
        return sample

    for index in range(len(COMPOSITION_LETTERS)):
        sample = take(EVENT_KEY_DOWN, f'组合字母 {index + 1}')
        if sample is not None and commit_observed(sample):
            problems.append(f'{prefix}组合字母 {index + 1} 事件不应插字，实际插字 '
                            f'{commit_count(sample)} 次')
    if confirm['id'] == 'shift':
        press = take(EVENT_FLAGS_CHANGED, 'Shift 按下')
        if press is not None and commit_observed(press):
            problems.append(f'{prefix}Shift 按下事件不应插字（应在释放事件）')
        release = take(EVENT_FLAGS_CHANGED, 'Shift 释放')
        if release is not None and commit_count(release) != 1:
            problems.append(f'{prefix}Shift 释放事件插字次数不符：期望 1，'
                            f'实际 {commit_count(release)}')
    else:
        sample = take(EVENT_KEY_DOWN, '确认键')
        if sample is not None and commit_count(sample) != 1:
            problems.append(f'{prefix}确认键事件插字次数不符：期望 1，'
                            f'实际 {commit_count(sample)}')
    expected = expected_insert_events(confirm, post)
    if post['kind'] == 'punctuation':
        sample = take(EVENT_KEY_DOWN, '标点后键')
        if sample is not None and commit_count(sample) != 1:
            problems.append(f'{prefix}标点后键事件插字次数不符：期望 1，'
                            f'实际 {commit_count(sample)}（漏字或重复）')
    elif post['id'] == 'letter':
        for what in ('字母后键', '续输字母'):
            sample = take(EVENT_KEY_DOWN, what)
            if sample is not None and commit_observed(sample):
                problems.append(f'{prefix}{what}事件不应插字，实际插字 '
                                f'{commit_count(sample)} 次')
    if pos != len(block):
        aligned = False
        problems.append(f'{prefix}样本流结构不符：消费 {pos} 个样本，'
                        f'本轮共 {len(block)} 个（疑似额外事件或残缺）')
    for sample in block:
        if commit_observed(sample):
            if sample.get('confirmationHidden') is not True:
                problems.append(f'{prefix}插字事件（id {sample.get("id")}）'
                                '提交时候选窗未在回调内隐藏')
            if sample.get('visibleAtReturn') is True:
                problems.append(f'{prefix}插字事件（id {sample.get("id")}）'
                                '回调结束时候选窗仍可见')
    return problems, aligned


def build_plan(hosts, iterations):
    """完整矩阵参数化：host × target × 确认方式 × 后键。"""
    groups = []
    for host in hosts:
        for target in TARGETS.get(host, ['default']):
            for confirm in CONFIRMATIONS:
                for post in POST_KEYS:
                    groups.append({
                        'id': f'{host}/{target}/{confirm["id"]}/{post["id"]}',
                        'host': host,
                        'target': target,
                        'confirm': confirm['id'],
                        'post': post['id'],
                        'iterations': iterations,
                    })
    plan = {
        'schema': 'gogaku.first-key-plan.v1',
        'createdAt': now_iso(),
        'composition': COMPOSITION,
        'iterations': iterations,
        'hosts': list(hosts),
        'confirmations': [{'id': c['id'], 'label': c['label'], 'committed': c['committed']}
                          for c in CONFIRMATIONS],
        'postKeys': [{'id': p['id'], 'label': p['label'], 'kind': p['kind']} for p in POST_KEYS],
        'groups': groups,
    }
    plan['sha256'] = sha256_text(json.dumps(
        {k: v for k, v in plan.items() if k not in ('createdAt', 'sha256')},
        ensure_ascii=False, sort_keys=True))
    return plan


# 黄金期望表：每种「确认方式 × 后键」组合的精确期望（人工核定）。
# 字段：已确认正文、输入区字母、光标位置（marked_visible 视图）、候选窗可见。
GOLDEN_EXPECTATIONS = {
    ('space', 'letter'): ('你好', 'n', 3, True),
    ('space', 'comma'): ('你好，', '', 3, False),
    ('space', 'period'): ('你好。', '', 3, False),
    ('space', 'stop'): ('你好', '', 2, False),
    ('enter', 'letter'): ('nihc', 'n', 5, True),
    ('enter', 'comma'): ('nihc，', '', 5, False),
    ('enter', 'period'): ('nihc。', '', 5, False),
    ('enter', 'stop'): ('nihc', '', 4, False),
    ('digit1', 'letter'): ('你好', 'n', 3, True),
    ('digit1', 'comma'): ('你好，', '', 3, False),
    ('digit1', 'period'): ('你好。', '', 3, False),
    ('digit1', 'stop'): ('你好', '', 2, False),
    ('semicolon', 'letter'): ('你好；', 'n', 4, True),
    ('semicolon', 'comma'): ('你好；，', '', 4, False),
    ('semicolon', 'period'): ('你好；。', '', 4, False),
    ('semicolon', 'stop'): ('你好；', '', 3, False),
    ('shift', 'letter'): ('nihc', 'n', 5, True),
    ('shift', 'comma'): ('nihc，', '', 5, False),
    ('shift', 'period'): ('nihc。', '', 5, False),
    ('shift', 'stop'): ('nihc', '', 4, False),
}


def expectation_self_test():
    """黄金表核对：不发事件，核对 5×4 组合的精确期望。"""
    problems = []
    for confirm in CONFIRMATIONS:
        for post in POST_KEYS:
            key = (confirm['id'], post['id'])
            if key not in GOLDEN_EXPECTATIONS:
                problems.append(f'黄金表缺少组合 {key}')
                continue
            committed, marked, caret, panel = GOLDEN_EXPECTATIONS[key]
            result = expected_result(confirm, post, 'marked_visible')
            if result['committed'] != committed:
                problems.append(f'{key} 正文期望：{result["committed"]!r} ≠ {committed!r}')
            if result['marked'] != marked:
                problems.append(f'{key} 输入区字母期望：{result["marked"]!r} ≠ {marked!r}')
            if result['caret'] != caret:
                problems.append(f'{key} 光标期望：{result["caret"]} ≠ {caret}')
            if result['panel'] != panel:
                problems.append(f'{key} 候选窗可见期望：{result["panel"]} ≠ {panel}')
            plain = expected_result(confirm, post, 'committed_only')
            if plain['value'] != committed:
                problems.append(f'{key} committed_only 视图正文期望错误')
            if plain['caret'] != (len(committed) + (0 if post['kind'] != 'composition' else 0)):
                problems.append(f'{key} committed_only 视图光标期望错误：{plain["caret"]}')
    for key in GOLDEN_EXPECTATIONS:
        if not any(c['id'] == key[0] for c in CONFIRMATIONS) \
                or not any(p['id'] == key[1] for p in POST_KEYS):
            problems.append(f'黄金表含未知组合 {key}')
    return problems


# --------------------------------------------------------------------------
# 合成回归：不发事件，验证插字核算本身（正确的两次插字不误报；漏字／重复仍失败）
# --------------------------------------------------------------------------

def synthetic_sample(event_type, sample_id, *, commits=0, hidden=True, visible_at_return=False):
    sample = {'id': sample_id, 'type': event_type, 'consumed': True,
              'visibleAtReturn': visible_at_return}
    if commits > 0:
        sample['commitCallNs'] = 1_000_000
        sample['commitCount'] = commits
        sample['confirmationHidden'] = hidden
    return sample


def synthetic_iteration(confirm, post, *, confirm_commits=None, post_commits=None,
                         letter_commits=0, confirm_hidden=True):
    """构造一次迭代的样本流（合成，不发事件，不碰真实输入源）。"""
    block = [synthetic_sample(EVENT_KEY_DOWN, index + 1) for index in range(4)]
    next_id = 5
    if confirm['id'] == 'shift':
        block.append(synthetic_sample(EVENT_FLAGS_CHANGED, next_id)); next_id += 1
        commits = 1 if confirm_commits is None else confirm_commits
        block.append(synthetic_sample(EVENT_FLAGS_CHANGED, next_id, commits=commits,
                                      hidden=confirm_hidden)); next_id += 1
    else:
        commits = 1 if confirm_commits is None else confirm_commits
        block.append(synthetic_sample(EVENT_KEY_DOWN, next_id, commits=commits,
                                      hidden=confirm_hidden)); next_id += 1
    if post['kind'] == 'punctuation':
        commits = 1 if post_commits is None else post_commits
        block.append(synthetic_sample(EVENT_KEY_DOWN, next_id, commits=commits))
    elif post['id'] == 'letter':
        block.append(synthetic_sample(EVENT_KEY_DOWN, next_id, commits=letter_commits)); next_id += 1
        block.append(synthetic_sample(EVENT_KEY_DOWN, next_id, commits=letter_commits))
    return block


def insert_accounting_self_test():
    """插字核算合成回归（离线）：
    1. 期望次数表：逗号／句号后键每轮两次插字，其余一次；
    2. 正确的两次插字（含 Shift 释放事件）不误报；
    3. 漏字、重复插字、插在错误事件、隐藏失败都会被判失败。
    """
    problems = []
    by_id = lambda items, wanted: next(item for item in items if item['id'] == wanted)
    space = by_id(CONFIRMATIONS, 'space')
    enter = by_id(CONFIRMATIONS, 'enter')
    shift = by_id(CONFIRMATIONS, 'shift')
    letter = by_id(POST_KEYS, 'letter')
    comma = by_id(POST_KEYS, 'comma')
    period = by_id(POST_KEYS, 'period')
    stop = by_id(POST_KEYS, 'stop')

    def expect_clean(name, confirm, post, **kwargs):
        block = synthetic_iteration(confirm, post, **kwargs)
        issues, aligned = verify_iteration_samples(confirm, post, block)
        if issues or not aligned:
            problems.append(f'合成[{name}]：正确行为被误报 → {issues}')

    def expect_dirty(name, confirm, post, needle, **kwargs):
        block = synthetic_iteration(confirm, post, **kwargs)
        issues, _ = verify_iteration_samples(confirm, post, block)
        if not any(needle in issue for issue in issues):
            problems.append(f'合成[{name}]：未检出缺陷（{needle}）→ {issues}')

    # 1. 期望次数表：全部 20 组合。
    for confirm_item in CONFIRMATIONS:
        for post_item in POST_KEYS:
            expected = expected_iteration_insert_total(confirm_item, post_item)
            wanted = 2 if post_item['kind'] == 'punctuation' else 1
            if expected != wanted:
                problems.append(f'合成[期望表] {confirm_item["id"]}/{post_item["id"]}：'
                                f'插字期望 {expected} ≠ {wanted}')
    # 2. 正确路径不误报。
    expect_clean('空格＋逗号＝两次插字', space, comma)
    expect_clean('空格＋句号＝两次插字', space, period)
    expect_clean('Shift＋句号（释放事件插字）', shift, period)
    expect_clean('Enter＋字母（仅确认一次）', enter, letter)
    expect_clean('空格＋停止（仅确认一次）', space, stop)
    # 3. 漏字。
    expect_dirty('标点漏字（样本流）', space, comma, '标点后键', post_commits=0)
    expect_dirty('确认漏字（样本流）', space, comma, '确认键', confirm_commits=0)
    expect_dirty('Shift 释放漏字（样本流）', shift, period, '释放', confirm_commits=0)
    # 4. 重复插字。
    expect_dirty('标点事件内重复插字', space, comma, '重复', post_commits=2)
    expect_dirty('字母后键事件插字（重复）', enter, letter, '不应插字', letter_commits=1)
    block = synthetic_iteration(enter, stop)
    stray = synthetic_sample(EVENT_KEY_DOWN, 99, commits=1)
    issues, _ = verify_iteration_samples(enter, stop, block[:3] + [stray] + block[3:])
    if not any('组合字母' in issue or '结构不符' in issue for issue in issues):
        problems.append(f'合成[组合字母事件插字（串扰）]：未检出 → {issues}')
    # 5. 隐藏状态失败。
    expect_dirty('确认插字未隐藏', space, comma, '未在回调内隐藏', confirm_hidden=False)
    # 6. 计数器口径：漏字／重复／正确。
    if verify_insert_delta(space, comma, 2, '空格＋逗号'):
        problems.append('合成[计数器]：正确的两次插字被误报')
    for delta, needle in ((1, '漏字'), (0, '漏字'), (3, '重复插字'), (4, '重复插字')):
        issues = verify_insert_delta(space, comma, delta, '空格＋逗号')
        if not issues or needle not in issues[0]:
            problems.append(f'合成[计数器]：delta={delta} 未按「{needle}」判失败 → {issues}')
    if verify_insert_delta(enter, letter, 1, 'Enter＋字母'):
        problems.append('合成[计数器]：字母后键的正确一次插字被误报')
    if not verify_insert_delta(enter, letter, 2, 'Enter＋字母'):
        problems.append('合成[计数器]：字母后键多一次插字未被检出')
    return problems


def plan_self_test(plan):
    """计划自检：不发事件，检查矩阵完整、无重复、期望自洽。"""
    problems = []
    confirm_ids = {c['id'] for c in CONFIRMATIONS}
    post_ids = {p['id'] for p in POST_KEYS}
    if len(confirm_ids) != len(CONFIRMATIONS):
        problems.append('确认方式 id 重复')
    if len(post_ids) != len(POST_KEYS):
        problems.append('后键 id 重复')
    expected_groups = 0
    for host in plan['hosts']:
        targets = TARGETS.get(host, ['default'])
        for target in targets:
            expected_groups += len(CONFIRMATIONS) * len(POST_KEYS)
    if len(plan['groups']) != expected_groups:
        problems.append(f'分组数 {len(plan["groups"])} ≠ 期望 {expected_groups}')
    seen = set()
    for group in plan['groups']:
        if group['id'] in seen:
            problems.append(f'重复分组：{group["id"]}')
        seen.add(group['id'])
        if group['confirm'] not in confirm_ids:
            problems.append(f'未知确认方式：{group["confirm"]}')
        if group['post'] not in post_ids:
            problems.append(f'未知后键：{group["post"]}')
        if group['iterations'] != plan['iterations']:
            problems.append(f'{group["id"]} 的轮次数与计划不一致')
        confirm = next((c for c in CONFIRMATIONS if c['id'] == group['confirm']), None)
        post = next((p for p in POST_KEYS if p['id'] == group['post']), None)
        if confirm and post:
            for view in ('committed_only', 'marked_visible'):
                result = expected_result(confirm, post, view)
                if not result['committed']:
                    problems.append(f'{group["id"]} 的期望正文为空')
                if result['caret'] < 0:
                    problems.append(f'{group["id"]} 的期望光标非法')
                if result['value'] != result['committed'] + (
                        post['marked'] if (view == 'marked_visible' and post['kind'] == 'composition') else ''):
                    problems.append(f'{group["id"]} 的 {view} 期望不自洽')
                if result['panel'] != (post['kind'] == 'composition'):
                    problems.append(f'{group["id"]} 的候选窗可见性期望不自洽')
    return problems


# --------------------------------------------------------------------------
# 候选窗状态 socket 客户端（ValidationMonitor 协议）
# --------------------------------------------------------------------------

REQUIRED_STATE_FIELDS = ('visible', 'generation', 'hideCount', 'staleRenderCount',
                         'renderCount', 'confirmationCount', 'confirmationHideFailures',
                         'scenario')


class PanelStateClient:
    """私有 socket 客户端：state / metrics / reset，响应只有状态与计数，没有文字。"""

    def __init__(self, path=None, timeout=5.0):
        self.path = str(path or DEFAULT_SOCKET)
        self.timeout = timeout

    def available(self):
        """真实可用性检查：socket 文件可能残留（输入法重启后的陈旧文件），
        必须实际问答一次才算可用。"""
        try:
            self.state()
            return True
        except PanelStateError:
            return False

    def command(self, name):
        try:
            with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as client:
                client.settimeout(self.timeout)
                client.connect(self.path)
                client.sendall((name + '\n').encode('utf-8'))
                chunks = []
                while True:
                    data = client.recv(65536)
                    if not data:
                        break
                    chunks.append(data)
                    if b'\n' in data:
                        break
        except OSError as error:
            raise PanelStateError(f'候选窗状态 socket 不可用：{error}') from error
        text = b''.join(chunks).decode('utf-8', 'replace').strip()
        if not text:
            raise PanelStateError('候选窗状态 socket 返回空响应')
        try:
            payload = json.loads(text.splitlines()[0])
        except json.JSONDecodeError as error:
            raise PanelStateError(f'候选窗状态响应不是 JSON：{text[:120]}') from error
        for field in REQUIRED_STATE_FIELDS:
            if field not in payload:
                raise PanelStateError(f'候选窗状态响应缺字段 {field}：{text[:120]}')
        return payload

    def state(self):
        return self.command('state')

    def scenario(self, name):
        """给后续样本打场景标识（归因实验用）。"""
        try:
            with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as client:
                client.settimeout(self.timeout)
                client.connect(self.path)
                client.sendall((f'scenario {name}\n').encode('utf-8'))
                chunks = []
                while True:
                    data = client.recv(65536)
                    if not data:
                        break
                    chunks.append(data)
                    if b'\n' in data:
                        break
        except OSError as error:
            raise PanelStateError(f'场景标识设置失败：{error}') from error
        text = b''.join(chunks).decode('utf-8', 'replace').strip()
        try:
            payload = json.loads(text.splitlines()[0])
        except json.JSONDecodeError as error:
            raise PanelStateError(f'场景标识响应不是 JSON：{text[:120]}') from error
        if not payload.get('accepted'):
            raise PanelStateError(f'场景标识被拒绝：{text[:120]}')
        return payload

    def metrics(self):
        payload = self.command('metrics')
        payload.setdefault('samples', [])
        return payload

    def reset(self):
        return self.command('reset')


def summarize_samples(samples):
    """把耗时样本压成可核对的摘要（不含任何文字）。

    口径声明：commitCallNs 仅覆盖 insertText 调用时长，不含核心选词与宿主实际
    接收；宿主端没有「收到文字」时间戳，所以「选中候选到宿主收到文字」的门槛在
    本探针里无法验证，不得拿它当通过证据。
    """
    summary = {'count': len(samples),
               'metricScope': {
                   'callbackNs': 'IMK handle 回调总时长（主线程实测）',
                   'coreNs': '共享核心同步处理时长',
                   'renderNs': '按键到候选渲染完成（含排队）',
                   'firstDisplayNs': '组合首键到候选首次显示',
                   'commitCallNs': ('仅 insertText 调用时长；不含核心选词与宿主实际接收，'
                                    '不能作为端到端门槛证据'),
               }}
    for field in ('callbackNs', 'coreNs', 'commitCallNs', 'renderNs', 'firstDisplayNs'):
        values = [s[field] for s in samples if isinstance(s.get(field), (int, float))]
        if not values:
            continue
        values.sort()
        summary[field] = {
            'count': len(values),
            'p50': int(statistics.median(values)),
            'p95': values[min(len(values) - 1, int(len(values) * 0.95))],
            'p99': values[min(len(values) - 1, int(len(values) * 0.99))],
            'max': values[-1],
        }
    confirmations = [s for s in samples if 'confirmationHidden' in s]
    summary['confirmationSamples'] = len(confirmations)
    summary['confirmationHiddenFalse'] = sum(1 for s in confirmations if not s.get('confirmationHidden'))
    summary['visibleAtReturnTrue'] = sum(1 for s in confirmations if s.get('visibleAtReturn') is True)
    summary['firstDisplayCount'] = sum(1 for s in samples if s.get('firstDisplay'))
    return summary


# --------------------------------------------------------------------------
# 驱动：探针宿主进程 + 常驻 AX 读取进程
# --------------------------------------------------------------------------

class Driver:
    """探针宿主（注入按键＋读取自身文本）与常驻 AX 读取进程。"""

    def __init__(self, workdir=None):
        self.temp = Path(workdir or tempfile.mkdtemp(prefix='gogaku-firstkey-'))
        self.owns_temp = workdir is None
        self.proc = None
        self.ax_proc = None
        self.ax_binary = self.temp / 'ax-reader'
        self.notify_binary = None
        self.probe_pid = None
        self.original_source = ''
        self.original_application = ''

    def build(self):
        contents = self.temp / 'Gogaku IMK Probe.app/Contents'
        (contents / 'MacOS').mkdir(parents=True, exist_ok=True)
        (contents / 'Info.plist').write_bytes(plistlib.dumps({
            'CFBundleIdentifier': PROBE_BUNDLE_ID, 'CFBundleName': 'Gogaku IMK Probe',
            'CFBundleExecutable': 'Probe', 'CFBundlePackageType': 'APPL',
            'NSHighResolutionCapable': True,
        }))
        executable = contents / 'MacOS/Probe'
        subprocess.check_call(['swiftc', str(ROOT / 'probes/imk-regression-host.swift'),
                               '-o', str(executable)], env=ENV)
        subprocess.check_call(['codesign', '--force', '--sign', '-', str(contents.parent)], env=ENV)
        subprocess.check_call(['swiftc', str(ROOT / 'probes/ax-reader.swift'),
                               '-o', str(self.ax_binary)], env=ENV)
        self.notify_binary = self.temp / 'post-notification'
        subprocess.check_call(['swiftc', str(ROOT / 'probes/post-notification.swift'),
                               '-o', str(self.notify_binary)], env=ENV)
        self.proc = subprocess.Popen([str(executable)], stdin=subprocess.PIPE,
                                     stdout=subprocess.PIPE, text=True, bufsize=1, env=ENV)
        ready = self._read_line()
        if not ready.get('ready'):
            raise HostError('探针宿主启动失败')
        self.probe_pid = ready.get('pid')
        self.original_source = ready.get('originalSource', '')
        self.original_application = ready.get('originalApplication', '')
        self.ax_proc = subprocess.Popen([str(self.ax_binary), '--stdin'], stdin=subprocess.PIPE,
                                        stdout=subprocess.PIPE, text=True, bufsize=1, env=ENV)
        return ready

    def _read_line(self, timeout=30):
        if not select.select([self.proc.stdout], [], [], timeout)[0]:
            raise HostError('探针宿主响应超时')
        line = self.proc.stdout.readline()
        if not line:
            raise HostError('探针宿主已退出')
        return json.loads(line)

    def ask(self, **request):
        self.proc.stdin.write(json.dumps(request) + '\n')
        self.proc.stdin.flush()
        return self._read_line()

    def ax(self, **command):
        self.ax_proc.stdin.write(json.dumps(command) + '\n')
        self.ax_proc.stdin.flush()
        if not select.select([self.ax_proc.stdout], [], [], 15)[0]:
            raise HostError('AX 读取进程响应超时')
        line = self.ax_proc.stdout.readline()
        if not line:
            raise HostError('AX 读取进程已退出')
        return json.loads(line)

    def close(self):
        if self.proc is not None and self.proc.poll() is None:
            try:
                self.ask(op='focus', field=1)
                if self.original_source:
                    self.ask(op='select', id=self.original_source)
                if self.original_application:
                    self.ask(op='frontApp', id=self.original_application)
            except (OSError, HostError):
                pass
        for proc, payload in ((self.ax_proc, {'op': 'quit'}), (self.proc, {'op': 'quit'})):
            if proc is None:
                continue
            try:
                proc.stdin.write(json.dumps(payload) + '\n')
                proc.stdin.flush()
                proc.wait(timeout=5)
            except Exception:
                try:
                    proc.kill()
                except Exception:
                    pass
        if self.owns_temp:
            shutil.rmtree(self.temp, ignore_errors=True)


# --------------------------------------------------------------------------
# 宿主会话：每个宿主只操作本次运行创建的专属目标
# --------------------------------------------------------------------------

class Session:
    """宿主会话接口。

    value_view：'marked_visible'（宿主文本包含输入区字母）或 'committed_only'。
    """

    name = ''
    bundle = ''
    marker = ''
    value_view = 'committed_only'
    supports_caret = True
    supports_marked = False

    def effective_view(self, letters_enabled=True):
        """输入区字母关掉时，宿主不再持有 marked text，观测退化为已确认正文。"""
        if self.value_view == 'marked_visible' and not letters_enabled:
            return 'committed_only'
        return self.value_view

    def open(self):
        raise NotImplementedError

    def close(self):
        raise NotImplementedError

    def focus_target(self):
        raise NotImplementedError

    def reset_field(self):
        raise NotImplementedError

    def read(self):
        raise NotImplementedError

    def send(self, steps):
        raise NotImplementedError


class BaseSession(Session):
    """共用：前台身份守卫与按键投递。"""

    def __init__(self, driver, run_id, guard_check=True):
        self.driver = driver
        self.run_id = run_id
        self.guard_check = guard_check
        self.guard_bundle = ''
        self.guard_pid = 0
        self.guard_marker = ''

    def front_identity(self):
        info = self.driver.ax(op='check', marker=self.guard_marker)
        if not info.get('ok'):
            raise GuardError(f'AX 无法读取前台应用：{info.get("reason")}')
        return info

    def assert_front(self):
        """强断言前台应用身份与专属测试目标身份；不通过抛 GuardError。

        空标题是 AX 焦点窗口的瞬态缺失（冷启动／激活切换瞬间），不代表目标错误：
        有限重读；重读后仍空或不匹配即中止。按键在本断言通过前不会发出。
        """
        if not self.guard_check:
            return None
        info = self.front_identity()
        attempts = 0
        while (info.get('title') == '' and info.get('frontBundle') == self.guard_bundle
               and attempts < 5):
            time.sleep(0.25)
            info = self.front_identity()
            attempts += 1
        front_bundle = info.get('frontBundle') or ''
        ax_bundle = info.get('axBundle') or ''
        if self.guard_bundle and front_bundle != self.guard_bundle:
            raise GuardError(f'前台应用不是预期宿主：{front_bundle!r} ≠ {self.guard_bundle!r}')
        if self.guard_bundle and ax_bundle and ax_bundle != self.guard_bundle:
            raise GuardError(f'AX 焦点应用不是预期宿主：{ax_bundle!r} ≠ {self.guard_bundle!r}')
        if self.guard_pid and int(info.get('pid') or 0) != int(self.guard_pid):
            raise GuardError(f'前台进程不是预期宿主：{info.get("pid")} ≠ {self.guard_pid}')
        if self.guard_marker and not info.get('markerOk'):
            raise GuardError(f'前台窗口标题不含本轮标记：{info.get("title")!r}')
        return info

    def send(self, steps):
        self.assert_front()
        reply = self.driver.ask(op='combo', steps=steps,
                                guard={'bundle': self.guard_bundle,
                                       'pid': self.guard_pid,
                                       'marker': self.guard_marker},
                                delay=0.12)
        if not reply.get('guardOk'):
            raise GuardError(f'探针拒绝投递：{reply.get("guardReason")} '
                             f'（前台 {reply.get("guardFront")}）')
        return reply

    def sleep(self, seconds):
        time.sleep(seconds)


class ProbeSession(BaseSession):
    """探针自身窗口（AppKit NSTextView）：可见 marked text 与光标，最严格。"""

    name = 'probe'
    bundle = PROBE_BUNDLE_ID
    value_view = 'marked_visible'
    supports_marked = True

    def open(self):
        self.marker = f'GOGAKU-PROBE-{self.run_id}-probe'
        reply = self.driver.ask(op='setMarker', marker=self.marker)
        self.guard_bundle = PROBE_BUNDLE_ID
        self.guard_pid = reply.get('frontPid') or 0
        self.guard_marker = self.marker
        self.driver.ask(op='focus', field=1)
        return reply

    def close(self):
        return None

    def focus_target(self):
        self.driver.ask(op='focus', field=1)

    def reset_field(self):
        # 先用真实 Esc 按键让输入法同步取消组合（核心状态与宿主一起清理），
        # 再程序化清空正文。直接 unmarkText 会把宿主 marked text 撤掉而核心
        # 组合仍在，下一轮字母会拼进残留组合（实测「你你好／出你好」残留路径）。
        self.send([[{'key': 'esc'}]])
        self.driver.ask(op='reset')

    def read(self):
        state = self.driver.ask(op='state')
        marked = state.get('marked') or {}
        return {
            'value': state.get('rawText', ''),
            'committed': state.get('text', ''),
            'caret': (state.get('selection') or [0, 0])[0],
            'marked': marked.get('text', ''),
            'markedRange': [marked.get('location', -1), marked.get('length', 0)],
        }


class TextEditSession(BaseSession):
    """TextEdit：本次运行新建的专属文档（名字含本轮标记），只关这一份。

    本机 TextEdit 已不提供文档 id 的 AppleScript 访问（-1728），按名字引用。
    """

    name = 'textedit'
    bundle = 'com.apple.TextEdit'
    value_view = 'marked_visible'

    def open(self):
        self.marker = f'GOGAKU-PROBE-{self.run_id}-textedit'
        self.temp_dir = Path(tempfile.mkdtemp(prefix='gogaku-firstkey-textedit-'))
        self.doc_path = self.temp_dir / f'{self.marker}.txt'
        self.doc_path.write_text('')
        # 本机 TextEdit 的未保存文档不能用 AppleScript 改名（标题会回退成「未命名」，
        # 「save in」也不会绑定文件名）；先建文件再 open，窗口标题持久等于标记。
        script = f'''
tell application "TextEdit"
    open POSIX file "{self.doc_path}"
    delay 0.6
    activate
    return name of front document
end tell
'''
        opened = osa(script, timeout=30).splitlines()[0].strip()
        if self.marker not in opened:
            raise HostError(f'TextEdit 文档打开失败：{opened!r}')
        self.guard_bundle = self.bundle
        self.guard_marker = self.marker
        time.sleep(0.6)
        return {'docName': opened, 'path': str(self.doc_path)}

    def close(self):
        # 只关闭本轮创建的文档；绝不 close every document。
        script = f'''
tell application "TextEdit"
    try
        close (first document whose name is "{self.marker}") saving no
    end try
end tell
'''
        try:
            osa(script, timeout=15)
        except HostError:
            pass
        shutil.rmtree(getattr(self, 'temp_dir', Path('/nonexistent')), ignore_errors=True)

    def focus_target(self):
        osa('tell application "TextEdit" to activate', timeout=15)
        time.sleep(0.4)

    def reset_field(self):
        # Esc 取消组合 → Command+A 全选 → Delete 删除；都是宿主原生操作，
        # 不在组合活跃时直接改宿主文本（实测会崩宿主文本栈）。
        self.send([[{'key': 'esc'}]])
        self.send([[{'key': 'a', 'command': True}]])
        self.send([[{'key': 'delete'}]])

    def read(self):
        text = osa(f'tell application "TextEdit" to get text of front document', timeout=15)
        # 本机 TextEdit 已不提供 selection 的 AppleScript 访问（-1728）；
        # 光标回退到 AX 焦点元素选区（与浏览器同源），读不到时明确记未验证。
        caret = None
        caret_status = 'unverified-textedit-selection-not-readable'
        if getattr(self, '_selection_supported', True):
            try:
                selection = osa(f'tell application "TextEdit" to get selection of front document', timeout=15)
                if selection:
                    caret = int(selection.split(',')[0].strip())
                    caret_status = 'measured'
            except HostError:
                self._selection_supported = False
        if caret is None:
            info = self.driver.ax(op='front', texts=False)
            location = (info.get('selectedRange') or [-1, 0])[0]
            if isinstance(location, int) and location >= 0:
                caret = location
                caret_status = 'measured-ax'
        return {'value': text, 'committed': None, 'caret': caret,
                'caretStatus': caret_status, 'marked': None}


class BrowserSession(BaseSession):
    """Chrome／Safari 共用：本地测试页，窗口标题携带本轮运行标记。"""

    value_view = 'committed_only'

    def title(self):
        raise NotImplementedError

    def activate(self, url):
        raise NotImplementedError

    def open(self):
        self.marker = self.run_id
        self.page = ROOT / 'probes/real-host-test-page.html'
        url = f'file://{self.page}?run={self.run_id}'
        self.activate(url)
        time.sleep(3.0)
        self.guard_bundle = self.bundle
        self.guard_marker = self.marker
        return {'url': url}

    def page_state(self):
        title = self.title()
        marker = f'Gogaku Test {self.run_id} '
        index = title.find(marker)
        if index < 0:
            raise HostError(f'页面标题不含本轮标记：{title[:120]!r}')
        payload = title[index + len(marker):]
        start, end = payload.find('{'), payload.rfind('}')
        if start < 0 or end < start:
            raise HostError(f'页面标题载荷不可解析：{payload[:120]!r}')
        return json.loads(payload[start:end + 1])

    def focus_target(self, target):
        # 焦点落到页面里的目标字段：用页面标题里的 focus 字段确认，
        # 不依赖不稳定的网页 AX 树。
        for _ in range(12):
            try:
                state = self.page_state()
            except HostError:
                state = {}
            if state.get('focus') == target:
                return True
            self.send([[{'key': 'tab'}]])
            time.sleep(0.15)
        state = self.page_state()
        if state.get('focus') == target:
            return True
        raise HostError(f'无法把焦点放到目标字段 {target}（当前 {state.get("focus")!r}）')

    def reset_field(self):
        self.send([[{'key': 'esc'}]])
        self.send([[{'key': 'a', 'command': True}]])
        self.send([[{'key': 'delete'}]])

    def read(self):
        state = self.page_state()
        value = state.get('area') if self.target == 'textarea' else state.get('rich')
        caret = None
        caret_status = 'unverified-ax-selected-range-unavailable'
        if self.supports_caret:
            info = self.driver.ax(op='front', texts=False)
            location = (info.get('selectedRange') or [-1, 0])[0]
            if location is not None and location >= 0:
                caret = location
                caret_status = 'measured'
        return {'value': value or '', 'committed': None, 'caret': caret,
                'caretStatus': caret_status, 'marked': None}


class ChromeSession(BrowserSession):
    name = 'chrome'
    bundle = 'com.google.Chrome'

    def __init__(self, driver, run_id, target='textarea',
                 chrome_path='/Applications/Google Chrome.app'):
        super().__init__(driver, run_id)
        self.target = target
        self.chrome_path = Path(chrome_path)
        self.profile = Path(tempfile.mkdtemp(prefix='gogaku-firstkey-chrome-'))
        self.proc = None

    def activate(self, url):
        binary = self.chrome_path / 'Contents/MacOS/Google Chrome'
        if not binary.exists():
            raise HostError('Chrome 未安装')
        self.proc = subprocess.Popen([str(binary), f'--user-data-dir={self.profile}',
                                      '--no-first-run', '--no-default-browser-check', url], env=ENV)
        time.sleep(4.0)
        osa('tell application "Google Chrome" to activate', timeout=20)
        time.sleep(0.8)

    def title(self):
        return osa('tell application "Google Chrome" to get title of active tab of front window',
                   timeout=20)

    def close(self):
        if self.proc is not None:
            self.proc.terminate()
            try:
                self.proc.wait(timeout=5)
            except Exception:
                self.proc.kill()
        shutil.rmtree(self.profile, ignore_errors=True)


class SafariSession(BrowserSession):
    name = 'safari'
    bundle = 'com.apple.Safari'

    def __init__(self, driver, run_id, target='textarea'):
        super().__init__(driver, run_id)
        self.target = target

    def activate(self, url):
        subprocess.check_call(['open', url, '-a', 'Safari'], env=ENV)
        time.sleep(3.5)
        osa('tell application "Safari" to activate', timeout=20)
        time.sleep(0.8)

    def title(self):
        return osa('tell application "Safari" to name of front window', timeout=20)

    def close(self):
        # 只关闭标题含本轮标记的窗口；不碰用户既有标签页。
        script = f'''
tell application "Safari"
    repeat with w in windows
        try
            if name of w contains "{self.run_id}" then
                close w
                exit repeat
            end if
        end try
    end repeat
end tell
'''
        try:
            osa(script, timeout=20)
        except HostError:
            pass


class TerminalSession(BaseSession):
    """Terminal.app：本次运行新建的专属窗口（自定义标题含本轮标记）。

    Terminal 不暴露真实选区：字符串长度不能冒充实测光标。插入位置用行为学
    核对（移动光标后插入固定字符并核对全文，见 Runner.behavioral_caret_probe）。
    """

    name = 'terminal'
    bundle = 'com.apple.Terminal'
    value_view = 'marked_visible'
    supports_caret = False          # 无选区读取；不再用 len(line) 冒充光标
    behavioral_caret = True         # 无组合时用标记字符核核对插入位置
    line_editor = True              # shell 行编辑：Ctrl＋A 可把光标移到行首

    def open(self):
        self.marker = f'GOGAKU-PROBE-{self.run_id}-terminal'
        if not ((Path('/Applications/Terminal.app')).exists()
                or (Path('/System/Applications/Terminal.app')).exists()
                or (Path('/System/Applications/Utilities/Terminal.app')).exists()):
            raise HostError('Terminal.app 未安装（本机环境限制，记为跳过）')
        script = f'''
tell application "Terminal"
    set newTab to do script "exec zsh -f"
    set custom title of newTab to "{self.marker}"
    delay 0.3
    set winId to id of front window
    return (winId as string)
end tell
'''
        # zsh -f：不加载用户 rc，避免 precmd 钩子改写标签标题（窗口标题是专属目标
        # 身份的依据）；行编辑（zle）仍然可用，提示符在 open 时采集。
        self.window_id = osa(script).splitlines()[0].strip()
        self.guard_bundle = self.bundle
        self.guard_marker = self.marker
        time.sleep(0.8)
        self.prompt = self._raw_line()
        return {'windowId': self.window_id, 'prompt': self.prompt}

    def _raw_line(self):
        content = osa('tell application "Terminal" to get contents of tab 1 of front window', timeout=20)
        lines = [line for line in content.splitlines() if line.strip()]
        return lines[-1] if lines else ''

    def close(self):
        script = f'''
tell application "Terminal"
    try
        close (first window whose id is {self.window_id}) saving no
    end try
end tell
'''
        try:
            osa(script, timeout=20)
        except HostError:
            pass

    def focus_target(self):
        osa('tell application "Terminal" to activate', timeout=20)
        time.sleep(0.5)

    def reset_field(self):
        # 终端里用 Esc＋Ctrl＋C 清行：Ctrl＋U 依赖光标在行尾，且无组合时 Esc 会
        # 透传给 zsh 进入 meta 前缀态，破坏后续 Ctrl＋U；Ctrl＋C 直接废弃整行。
        self.send([[{'key': 'esc'}]])
        self.send([[{'key': 'c', 'control': True}]])

    def read(self):
        line = self._raw_line()
        prompt = getattr(self, 'prompt', '')
        value = line[len(prompt):] if prompt and line.startswith(prompt) else line
        if value.startswith(' '):
            value = value[1:]   # 提示符后的分隔空格（采集时被行尾裁掉）
        return {'value': value, 'committed': None, 'caret': None,
                'caretStatus': 'unverified-terminal-selection-not-readable',
                'rawLine': line, 'prompt': prompt, 'marked': None}


class OrcaPTYSession(BaseSession):
    """Orca 专属 PTY：本次运行新建的终端与独占的接收文件，不碰用户终端。

    原始 PTY 没有选区可读，光标位置无法实测：明确记为未验证，不用「跳过
    光标检查」冒充通过；字节顺序与内容仍由接收文件逐字核对，另用标记字符
    核对插入顺序（behavioral_caret，无行编辑故不做行首插入）。
    """

    name = 'orca-pty'
    bundle = 'com.stablyai.orca'
    value_view = 'committed_only'
    supports_caret = False
    behavioral_caret = True
    line_editor = False

    def open(self):
        self.marker = f'GOGAKU-PROBE-{self.run_id}-orca'
        self.temp = Path(tempfile.mkdtemp(prefix='gogaku-firstkey-pty-'))
        self.received = self.temp / 'received.bin'
        self.baseline = 0   # 接收进程会重写累积缓冲，截断文件无效；按偏移取本轮新增
        receiver = ROOT / 'probes/imk-terminal-receiver.py'
        command = f'python3 {receiver} {self.received}'
        created = self.orca('terminal', 'create', '--worktree', 'path:' + str(ROOT),
                            '--title', self.marker, '--command', command)
        self.handle = created['terminal']['handle']
        self.orca('terminal', 'switch', '--terminal', self.handle)
        deadline = time.time() + 10
        while time.time() < deadline and not self.received.exists():
            time.sleep(0.2)
        if not self.received.exists():
            raise HostError('Orca PTY 接收文件未就绪')
        self.guard_bundle = self.bundle
        # Orca 的 AX 窗口标题是应用名，不含终端标签标题；专属目标身份由
        # 本轮独占的 PTY 文件与终端句柄保证（assert_front 的 bundle 检查）。
        self.guard_marker = ''
        return {'handle': self.handle, 'received': str(self.received)}

    def orca(self, *args):
        result = subprocess.check_output(['orca', *args, '--json'], cwd=ROOT, env=ENV,
                                         text=True, timeout=30)
        payload = json.loads(result)
        if not payload.get('ok'):
            raise HostError(f'orca 命令失败：{payload}')
        return payload['result']

    def close(self):
        try:
            self.orca('terminal', 'close', '--terminal', self.handle)
        except Exception:
            pass
        shutil.rmtree(getattr(self, 'temp', Path('/nonexistent')), ignore_errors=True)

    def focus_target(self):
        # switch 只选中终端标签，不保证应用在前台；显式激活 Orca。
        subprocess.run(['open', '-a', 'Orca'], env=ENV)
        self.orca('terminal', 'switch', '--terminal', self.handle)
        time.sleep(0.6)

    def reset_field(self):
        self.send([[{'key': 'esc'}]])
        # Esc 的透传字节（如无组合时）计入基线；此后新增字节即为本轮输入。
        if self.received.exists():
            self.baseline = len(self.received.read_bytes())

    def read(self):
        data = self.received.read_bytes() if self.received.exists() else b''
        return {'value': data[self.baseline:].decode('utf-8', 'replace'), 'committed': None,
                'caret': None,
                'caretStatus': 'unverified-pty-selection-not-readable',
                'marked': None}


SESSIONS = {
    'textedit': (TextEditSession, ['default']),
    'chrome': (ChromeSession, ['textarea', 'contenteditable']),
    'safari': (SafariSession, ['textarea', 'contenteditable']),
    'terminal': (TerminalSession, ['default']),
    'orca-pty': (OrcaPTYSession, ['default']),
    'probe': (ProbeSession, ['default']),
}


def make_session(driver, host, target, run_id):
    factory, _ = SESSIONS[host]
    if host in ('chrome', 'safari'):
        return factory(driver, run_id, target=target)
    return factory(driver, run_id)


# --------------------------------------------------------------------------
# 矩阵执行
# --------------------------------------------------------------------------

class Runner:
    def __init__(self, driver, panel, iterations, warmup=2, evidence=None,
                 stop_on_failure=False, panel_observation=2.0, panel_settle=1.0,
                 letters_enabled=None):
        self.driver = driver
        self.panel = panel
        self.iterations = iterations
        self.warmup = warmup
        self.evidence = evidence
        self.stop_on_failure = stop_on_failure
        self.panel_observation = panel_observation
        self.panel_settle = panel_settle
        self.letters_enabled = input_letters_enabled() if letters_enabled is None else letters_enabled
        self.checks = []
        self.failures = 0
        self.groups = []
        self.panel_reports = []

    # -- 记录 -------------------------------------------------------------
    def check(self, ok, name, detail='', group=None, iteration=None, phase='matrix'):
        record = {'check': name, 'ok': bool(ok), 'detail': str(detail)[:400],
                  'phase': phase, 'group': group, 'iteration': iteration,
                  'at': now_iso()}
        self.checks.append(record)
        if not ok:
            self.failures += 1
        print(('  ok   ' if ok else '  FAIL') + f' {name}' +
              (f'（{str(detail)[:120]}）' if detail else ''), flush=True)
        return ok

    def evidence_line(self, payload):
        if self.evidence is None:
            return
        with self.evidence.open('a') as handle:
            handle.write(json.dumps(payload, ensure_ascii=False) + '\n')

    # -- 面板状态 ---------------------------------------------------------
    def panel_state(self):
        if self.panel is None:
            return None
        try:
            return self.panel.state()
        except PanelStateError as error:
            self.check(False, '候选窗状态查询失败', str(error), phase='panel')
            return None

    def wait_panel(self, expect_visible, timeout=None):
        """轮询到期望的可见性；返回 (状态, 等待毫秒, 是否达到)。"""
        timeout = self.panel_settle if timeout is None else timeout
        start = time.time()
        last = None
        while True:
            last = self.panel_state()
            if last is None:
                return None, 0, False
            if bool(last.get('visible')) == bool(expect_visible):
                return last, int((time.time() - start) * 1000), True
            if time.time() - start >= timeout:
                return last, int((time.time() - start) * 1000), False
            time.sleep(0.02)

    # -- 单组 -------------------------------------------------------------
    def run_group(self, session, group):
        confirm = next(c for c in CONFIRMATIONS if c['id'] == group['confirm'])
        post = next(p for p in POST_KEYS if p['id'] == group['post'])
        view = session.effective_view(self.letters_enabled)
        expected = expected_result(confirm, post, view)
        passed, failed = 0, 0
        failures = []
        ran = 0
        caret_unverified = 0          # 光标无法实测的轮次（明确记未验证，不计为通过）
        sent_iterations = 0            # 实际发出确认键的轮次（含预热；含读取失败的轮次）
        expected_inserts_total = 0     # 这些轮次按确认＋后键分别累计的插字期望
        boundaries = []                # 每轮样本流边界 [start_events, end_events] 或 None
        host_read_errors = 0
        before = None
        if self.panel is not None:
            try:
                self.panel.reset()
                before = self.panel.state()
            except PanelStateError as error:
                self.check(False, f'{group["id"]}：面板统计清零失败', str(error),
                           group=group['id'], phase='panel')
                self.panel = None
        total = self.iterations + self.warmup
        for index in range(total):
            phase = 'warmup' if index < self.warmup else 'matrix'
            sent_holder = [False]
            try:
                observed, boundary = self.run_iteration(
                    session, group, confirm, post, expected, index, phase, sent_holder)
            except GuardError as error:
                self.check(False, f'{group["id"]}：前台身份断言失败，未投递按键', str(error),
                           group=group['id'], iteration=index, phase=phase)
                raise
            except HostError as error:
                self.check(False, f'{group["id"]}：宿主读取失败', str(error),
                           group=group['id'], iteration=index, phase=phase)
                failed += 1
                host_read_errors += 1
                failures.append({'iteration': index, 'reason': 'host-error', 'detail': str(error)})
                boundaries.append(None)
                if sent_holder[0]:
                    sent_iterations += 1
                    expected_inserts_total += expected_iteration_insert_total(confirm, post)
                if self.stop_on_failure:
                    break
                continue
            ran += 1
            sent_iterations += 1
            expected_inserts_total += expected_iteration_insert_total(confirm, post)
            boundaries.append(boundary)
            if observed.get('caretStatus') != 'measured':
                caret_unverified += 1
            ok = observed['ok']
            self.evidence_line({'group': group['id'], 'iteration': index, 'phase': phase,
                                'expected': expected, 'observed': observed, 'ok': ok,
                                'at': now_iso()})
            if ok:
                passed += 1
            else:
                failed += 1
                failures.append({'iteration': index, 'reason': 'mismatch', 'detail': observed})
                self.check(False, f'{group["id"]}：第 {index + 1} 次结果不符',
                           json.dumps(observed, ensure_ascii=False)[:300],
                           group=group['id'], iteration=index, phase=phase)
                if self.stop_on_failure:
                    break
        # 组级判定 1：插字计数器。确认与后键分别累计（逗号／句号后键每轮两次），
        # 漏字偏小、重复偏大都不通过；不再把每轮笼统算成一次提交。
        if before is not None and self.panel is not None:
            try:
                after = self.panel.state()
                metrics = self.panel.metrics()
            except PanelStateError as error:
                self.check(False, f'{group["id"]}：面板状态读取失败', str(error),
                           group=group['id'], phase='panel')
                after = None
                metrics = None
            if after is not None:
                confirmations = int(after.get('confirmationCount', 0))
                hide_failures = int(after.get('confirmationHideFailures', 0))
                self.check(confirmations == expected_inserts_total,
                           f'{group["id"]}：插字次数按确认与后键分别匹配',
                           f'发出 {sent_iterations} 轮，期望插字 {expected_inserts_total} 次'
                           f'（每轮确认 1 次＋标点后键 {1 if post["kind"] == "punctuation" else 0} 次），'
                           f'实际 {confirmations} 次',
                           group=group['id'], phase='panel')
                self.check(hide_failures == 0,
                           f'{group["id"]}：每次插字时候选窗均在回调内隐藏',
                           f'confirmationHideFailures 增加 {hide_failures}',
                           group=group['id'], phase='panel')
            # 组级判定 2：样本流归属。逐轮切出本轮事件，核对插字只落在确认事件
            # 与标点后键事件上，且每次插字都伴随回调内隐藏。
            if metrics is not None and host_read_errors == 0:
                samples = metrics.get('samples', [])
                attribution_problems = []
                parsed = 0
                for index, boundary in enumerate(boundaries):
                    if not boundary or boundary[0] is None or boundary[1] is None:
                        attribution_problems.append(f'第 {index + 1} 轮样本边界缺失')
                        continue
                    block = samples[boundary[0]:boundary[1]]
                    issues, aligned = verify_iteration_samples(
                        confirm, post, block, label=f'第 {index + 1} 轮')
                    if aligned:
                        parsed += 1
                    attribution_problems.extend(issues)
                self.check(not attribution_problems,
                           f'{group["id"]}：样本流插字归属与隐藏状态',
                           '；'.join(attribution_problems[:4]) if attribution_problems
                           else f'{parsed}/{len(boundaries)} 轮逐事件核对通过',
                           group=group['id'], phase='panel')
        self.groups.append({'id': group['id'], 'iterations': self.iterations,
                             'warmup': self.warmup, 'ran': ran, 'passed': passed,
                             'failed': failed, 'expected': expected,
                             'caretUnverified': caret_unverified,
                             'insertsPerIteration': expected_insert_events(confirm, post),
                             'failures': failures[:20]})

    # -- 单次迭代 ---------------------------------------------------------
    def run_iteration(self, session, group, confirm, post, expected, index, phase, sent_holder):
        session.reset_field()
        pre = self.panel_state()
        start_events = int(pre.get('events', 0)) if pre else None
        start_confirmations = int(pre.get('confirmationCount', 0)) if pre else None
        # 输入组合字母：同一步内背靠背投递（一次守卫检查）。
        session.send([[{'key': letter} for letter in COMPOSITION_LETTERS]])
        # 确认键与后键在同一次调用里背靠背投递：中间没有任何人为延迟。
        steps = list(confirm['steps']) + list(post['steps'])
        session.send(steps)
        sent_holder[0] = True
        observed = session.read()
        value = observed.get('value')
        caret = observed.get('caret')
        caret_status = observed.get('caretStatus') or (
            'measured' if caret is not None else 'unverified')
        problems = []
        if value != expected['value']:
            problems.append(f'正文不符：期望 {expected["value"]!r}，实际 {value!r}')
        if session.supports_caret and caret_status == 'measured' \
                and caret != expected['caret']:
            problems.append(f'光标不符：期望 {expected["caret"]}，实际 {caret}')
        if observed.get('committed') is not None and observed['committed'] != expected['committed']:
            problems.append(f'已确认正文不符：期望 {expected["committed"]!r}，'
                            f'实际 {observed["committed"]!r}')
        if session.supports_marked:
            marked = observed.get('marked') or ''
            expected_marked = expected['marked'] if (self.letters_enabled
                                                      and session.value_view == 'marked_visible') else ''
            if marked != expected_marked:
                problems.append(f'输入区字母不符：期望 {expected_marked!r}，实际 {marked!r}')
        # 再接一个字母，覆盖提交后首次读到旧选区、到第二键才误判换框的路径。
        continuation = None
        if post['kind'] == 'composition':
            session.send([[{'key': 'i'}]])
            continuation = session.read()
            suffix = 'ni' if session.effective_view(self.letters_enabled) == 'marked_visible' else ''
            if continuation.get('value') != expected['committed'] + suffix:
                problems.append(f'第二字母后正文不符：{continuation.get("value")!r}')
            if session.supports_marked and self.letters_enabled and continuation.get('marked') != 'ni':
                problems.append(f'第二字母没有进入组合：{continuation.get("marked")!r}')
        # 插入位置行为学核对（终端／PTY 读不到真实选区时）：固定字符必须落在
        # 已确认正文之后；行编辑宿主再把光标移到行首插入第二个标记核对全文。
        # 样本边界在探针前采集：标记键是额外事件，不属于本轮插字归属核对的块。
        caret_probe = None
        boundary_state = self.panel_state() if self.panel is not None else None
        if getattr(session, 'behavioral_caret', False) and post['kind'] in ('punctuation', 'stop'):
            caret_probe = self.behavioral_caret_probe(session, expected)
            problems.extend(caret_probe['problems'])
        post_state = self.panel_state()
        end_events = int(post_state.get('events', 0)) if post_state else None
        if boundary_state is not None:
            end_events = int(boundary_state.get('events', 0))
        inserts = None
        if pre is not None and post_state is not None:
            delta = int(post_state.get('confirmationCount', 0)) - start_confirmations
            inserts = {'expected': expected_iteration_insert_total(confirm, post),
                       'counted': delta}
            problems.extend(verify_insert_delta(confirm, post, delta,
                                                label=f'第 {index + 1} 轮'))
        panel_state = None
        panel_ok = None
        panel_ms = None
        if self.panel is not None:
            panel_state, panel_ms, panel_ok = self.wait_panel(expected['panel'])
            if not panel_ok:
                problems.append(f'候选窗可见性不符：期望 {expected["panel"]}，'
                                f'实际 {panel_state.get("visible") if panel_state else "不可读"}')
            # 每次确认都观察完整两秒；不发 Esc 掩盖残留，renderCount 检出
            # 观察期内曾重新渲染后又隐藏的瞬态。字母后键的新组合应保持稳定。
            time.sleep(self.panel_observation)
            after_observation = self.panel_state()
            if not after_observation or not panel_state:
                problems.append('两秒观察期间候选窗状态不可读')
            elif (after_observation.get('visible') != expected['panel']
                  or after_observation.get('renderCount') != panel_state.get('renderCount')):
                problems.append('两秒观察期内候选窗可见性变化或发生额外渲染')
        boundary = [start_events, end_events]
        return {'ok': not problems, 'value': value, 'caret': caret,
                'caretStatus': caret_status,
                'committed': observed.get('committed'), 'marked': observed.get('marked'),
                'panel': panel_state, 'panelWaitMs': panel_ms, 'continuation': continuation,
                'inserts': inserts, 'caretProbe': caret_probe, 'problems': problems}, boundary

    def behavioral_caret_probe(self, session, expected):
        """无组合状态下的插入位置行为学核对（读不到真实选区的宿主）。

        标记 1（数字 7，无组合时透传）：必须落在已确认正文之后——若输入法把
        光标留在错误位置，固定字符会插进正文中间，全文比对失败。
        标记 2（仅行编辑宿主）：Ctrl＋A 把光标移到行首后插入数字 8，核对全文。
        """
        result = {'session': session.name, 'markers': [], 'problems': []}
        baseline = expected['value']
        session.send([[{'key': '7'}]])
        first = session.read()
        result['markers'].append({'marker': '7', 'value': first.get('value')})
        if first.get('value') != baseline + '7':
            result['problems'].append(
                f'插入位置行为学核对：数字 7 未落在已确认正文之后——'
                f'期望 {baseline + "7"!r}，实际 {first.get("value")!r}')
        if getattr(session, 'line_editor', False):
            session.send([[{'key': 'a', 'control': True}], [{'key': '8'}]])
            second = session.read()
            result['markers'].append({'marker': 'ctrl-a+8', 'value': second.get('value')})
            if second.get('value') != '8' + baseline + '7':
                result['problems'].append(
                    f'行首插入核对：Ctrl＋A 后数字 8 未落在行首——'
                    f'期望 {("8" + baseline + "7")!r}，实际 {second.get("value")!r}')
            # 把光标移回行尾：否则下一轮 Ctrl＋U 只清到光标，残留正文累积。
            session.send([[{'key': 'e', 'control': True}]])
        return result

    # -- 拼音光标真实窗口核对 ---------------------------------------------
    # 期望值语义：小鹤双拼下 libime 的拼音光标在音节内吸附到「起点／声母后／
    # 韵尾」三档（fcitx5 同源行为）。组合 nihc（展开全拼 ni'hao＝6）：
    # 末尾 6 → Left 一个按键位＝4（h 与 ao 之间）→ 再 Left＝2（音节边界，撇号前）。
    # 原码显示（fullPinyinPreedit=false）无吸附：caret＝原码光标 0–4。
    CARET_SEQUENCE = [
        ('组合后光标在末尾', None, [6, 6]),
        ('Left（声母后）', [[{'key': 'left'}]], [6, 4]),
        ('再 Left（音节边界）', [[{'key': 'left'}]], [6, 2]),
        ('Right', [[{'key': 'right'}]], [6, 4]),
        ('Home', [[{'key': 'home'}]], [6, 0]),
        ('End', [[{'key': 'end'}]], [6, 6]),
        ('Ctrl＋A', [[{'key': 'a', 'control': True}]], [6, 0]),
        ('Ctrl＋E', [[{'key': 'e', 'control': True}]], [6, 6]),
        ('Ctrl＋B（声母后）', [[{'key': 'b', 'control': True}]], [6, 4]),
        ('Ctrl＋F（回末尾）', [[{'key': 'f', 'control': True}]], [6, 6]),
    ]

    def caret_state(self, settle=0.35):
        """等异步渲染落地后读面板插入点（真实窗口状态，仅数值）。"""
        time.sleep(settle)
        state = self.panel_state()
        if state is None:
            return None
        caret = state.get('panelPreeditCaret')
        if isinstance(caret, list) and len(caret) == 2:
            return {'caret': [int(caret[0]), int(caret[1])],
                    'visible': bool(state.get('visible')),
                    'windowNumber': state.get('panelWindowNumber')}
        return {'caret': None, 'visible': bool(state.get('visible')),
                'windowNumber': state.get('panelWindowNumber')}

    def capture_panel(self, window_number, path):
        """真实窗口截图（screencapture 指定窗口；仅存证供人工复核）。"""
        if not window_number or window_number <= 0:
            return None
        path.parent.mkdir(parents=True, exist_ok=True)
        result = subprocess.run(['screencapture', '-x', '-o', '-l', str(window_number),
                                 str(path)], capture_output=True, env=ENV)
        return str(path) if result.returncode == 0 and path.exists() else None

    def run_caret_probe(self, session, shots_dir=None):
        """拼音光标真实窗口核对：数值插点逐项比对 ＋ 真实窗口截图；
        另在原码显示（fullPinyinPreedit=false）下复测首两项。"""
        if self.panel is None:
            self.check(False, f'caret/{session.name}：拼音光标核对需要验收状态接口',
                       phase='caret', group=f'caret/{session.name}')
            return
        group_id = f'caret/{session.name}'
        original_settings = None
        try:
            for label, steps, expected in self.CARET_SEQUENCE:
                if steps is None:
                    session.reset_field()
                    session.send([[{'key': letter} for letter in COMPOSITION_LETTERS]])
                else:
                    session.send(steps)
                state = self.caret_state()
                observed = state.get('caret') if state else None
                ok = (state is not None and state.get('visible') is True
                      and observed == expected)
                self.check(ok, f'{group_id}：{label}插入点＝{expected}',
                           json.dumps(state, ensure_ascii=False),
                           phase='caret', group=group_id)
                if shots_dir is not None and label in ('组合后光标在末尾', 'Home'):
                    self.capture_panel(state.get('windowNumber'),
                                       shots_dir / f'caret-{session.name}-'
                                                   f'{"end" if label.startswith("组合") else "home"}.png')
            # 原码显示：设置切换后同一组合的插点（nihc＝4）；分段与展开全拼的像素
            # 定位已由离屏渲染 51 项覆盖，真实窗口链路用这两项代表。
            if self.driver.notify_binary is not None:
                original_settings = write_settings({'fullPinyinPreedit': False},
                                                   self.driver.notify_binary)
                session.reset_field()
                session.send([[{'key': letter} for letter in COMPOSITION_LETTERS]])
                state = self.caret_state()
                observed = state.get('caret') if state else None
                self.check(state and state.get('visible') is True and observed == [4, 4],
                           f'{group_id}：原码显示插入点在末尾＝[4, 4]',
                           json.dumps(state, ensure_ascii=False),
                           phase='caret', group=group_id)
                session.send([[{'key': 'left'}]])
                state = self.caret_state()
                observed = state.get('caret') if state else None
                self.check(state and state.get('visible') is True and observed == [4, 3],
                           f'{group_id}：原码显示 Left 后插入点＝[4, 3]',
                           json.dumps(state, ensure_ascii=False),
                           phase='caret', group=group_id)
        finally:
            session.send([[{'key': 'esc'}]])
            if original_settings is not None:
                restore = {key: value for key, value in original_settings.items()
                           if value is not None}
                if 'fullPinyinPreedit' not in restore:
                    restore['fullPinyinPreedit'] = True
                write_settings(restore, self.driver.notify_binary)
                session.reset_field()

    # -- 面板状态专测 -----------------------------------------------------
    def observe_no_reappear(self, session, group, label):
        """确认（且后键组合已清理）之后：候选窗在观察窗口内不重弹。"""
        if self.panel is None:
            return
        state = self.panel_state()
        if state is None:
            return
        if state.get('visible'):
            # 后键字母开了新组合：先清理，再观察；否则会把新窗当成旧窗重弹。
            session.send([[{'key': 'esc'}]])
            time.sleep(0.25)
        before = self.panel_state()
        if before is None:
            return
        time.sleep(self.panel_observation)
        after = self.panel_state()
        if after is None:
            return
        ok = (after.get('visible') is False
              and int(after.get('hideCount', 0)) == int(before.get('hideCount', 0))
              and int(after.get('staleRenderCount', 0)) == int(before.get('staleRenderCount', 0)))
        self.check(ok,
                   f'{group["id"]}：{label} {self.panel_observation:g} 秒内候选窗未重弹',
                   json.dumps({'before': before, 'after': after}, ensure_ascii=False),
                   group=group['id'], phase='panel')

    def run_panel_check(self, session, confirm):
        """单个确认方式：回调内隐藏 + 2 秒未重弹 + 样本级证据。"""
        group_id = f'panel/{confirm["id"]}'
        if self.panel is None:
            self.check(True, f'{group_id}：候选窗状态未启用（无 socket）',
                       phase='panel', group=group_id)
            return
        try:
            self.panel.reset()
        except PanelStateError as error:
            self.check(False, f'{group_id}：面板统计清零失败', str(error),
                       phase='panel', group=group_id)
            return
        session.reset_field()
        session.send([[{'key': letter} for letter in COMPOSITION_LETTERS]])
        composing, _, composing_ok = self.wait_panel(True)
        self.check(composing_ok, f'{group_id}：组合中候选窗可见',
                   json.dumps(composing, ensure_ascii=False) if composing else '不可读',
                   phase='panel', group=group_id)
        before_commit = self.panel_state()
        session.send(confirm['steps'])
        after_commit = self.panel_state()
        if before_commit and after_commit:
            hidden = after_commit.get('visible') is False
            counted = (int(after_commit.get('confirmationCount', 0))
                       > int(before_commit.get('confirmationCount', 0)))
            failures = (int(after_commit.get('confirmationHideFailures', 0))
                        == int(before_commit.get('confirmationHideFailures', 0)))
            self.check(hidden and counted and failures,
                       f'{group_id}：确认后候选窗在回调内隐藏',
                       json.dumps({'before': before_commit, 'after': after_commit},
                                  ensure_ascii=False),
                       phase='panel', group=group_id)
        try:
            metrics = self.panel.metrics()
        except PanelStateError as error:
            self.check(False, f'{group_id}：面板指标读取失败', str(error),
                       phase='panel', group=group_id)
            return
        summary = summarize_samples(metrics.get('samples', []))
        self.check(summary['confirmationSamples'] >= 1
                   and summary['confirmationHiddenFalse'] == 0
                   and summary['visibleAtReturnTrue'] == 0,
                   f'{group_id}：提交样本显示回调内已隐藏且回调结束时不可见',
                   json.dumps(summary, ensure_ascii=False),
                   phase='panel', group=group_id)
        self.panel_reports.append({'confirm': confirm['id'], 'summary': summary})
        self.observe_no_reappear(session, {'id': group_id}, '确认后')


# --------------------------------------------------------------------------
# CLI
# --------------------------------------------------------------------------

def main():
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--hosts', default='probe,textedit,chrome,safari,orca-pty',
                        help='逗号分隔：' + ','.join(HOST_ORDER))
    parser.add_argument('--iterations', type=int, default=200, help='每组轮次（默认 200）')
    parser.add_argument('--warmup', type=int, default=2, help='每组预热轮次（不计入矩阵）')
    parser.add_argument('--panel-state-socket', default=str(DEFAULT_SOCKET),
                        help='候选窗状态 socket 路径')
    parser.add_argument('--no-panel-state', action='store_true', help='不做候选窗状态判定')
    parser.add_argument('--enable-validation', action='store_true',
                        help='创建私有开关并重启输入法（启用验收状态接口）')
    parser.add_argument('--panel-observation', type=float, default=2.0,
                        help='候选窗未重弹观察窗口（秒）')
    parser.add_argument('--stop-on-failure', action='store_true', help='首个失败即停止')
    parser.add_argument('--caret-probe', action='store_true',
                        help='拼音光标真实窗口核对（数值插点＋真实窗口截图）')
    parser.add_argument('--shots-dir', type=Path, default=None,
                        help='真实窗口截图目录（--caret-probe 时使用）')
    parser.add_argument('--plan-only', action='store_true', help='只生成场景计划，不发事件')
    parser.add_argument('--plan-out', type=Path, default=None, help='场景计划输出路径')
    parser.add_argument('--self-test', action='store_true', help='计划自检（不发事件）')
    parser.add_argument('--report', type=Path, default=ROOT / 'docs/validation/first-key-matrix.json')
    parser.add_argument('--evidence', type=Path, default=None, help='逐轮证据 JSONL')
    parser.add_argument('--chrome-path', default='/Applications/Google Chrome.app')
    args = parser.parse_args()

    hosts = [h.strip() for h in args.hosts.split(',') if h.strip()]
    for host in hosts:
        if host not in SESSIONS:
            parser.error(f'未知宿主：{host}（可用：{",".join(HOST_ORDER)}）')

    plan = build_plan(hosts, args.iterations)
    problems = plan_self_test(plan) + expectation_self_test() + insert_accounting_self_test()
    if args.self_test or args.plan_only:
        if args.plan_out:
            args.plan_out.parent.mkdir(parents=True, exist_ok=True)
            args.plan_out.write_text(json.dumps(plan, ensure_ascii=False, indent=2) + '\n')
            print(f'场景计划已写入：{args.plan_out}')
        insert_problems = insert_accounting_self_test()
        print(f'计划自检：{len(plan["groups"])} 组 × {plan["iterations"]} 次；'
              f'插字核算合成回归 {"通过" if not insert_problems else "失败"}')
        print(f'合计问题 {len(problems)} 项')
        for problem in problems:
            print('  FAIL', problem)
        return 1 if problems else 0

    if args.enable_validation:
        marker = enable_validation_monitor()
        print(f'已创建验收开关：{marker}（已重启输入法进程）')

    run_id = f'{int(time.time())}{os.getpid() % 10000:04d}'
    evidence = args.evidence
    if evidence is None:
        evidence = args.report.with_suffix('.evidence.jsonl')
    evidence.parent.mkdir(parents=True, exist_ok=True)
    evidence.write_text('')

    panel = None
    if not args.no_panel_state:
        panel = PanelStateClient(args.panel_state_socket)

    driver = Driver()
    sessions = {}
    skipped = []
    try:
        ready = driver.build()
        print(f'探针宿主已启动（pid {ready.get("pid")}）')
        # 输入源切换只在探针自身窗口做（可靠路径），一次切到 Gogaku。
        state = driver.ask(op='select', id=SOURCE)
        if state.get('source') != SOURCE:
            print(f'输入源切换失败：当前 {state.get("source")!r}'
                  f'（Gogaku 需要用户先在系统设置里启用该输入源）')
            return 2
        if panel is not None:
            deadline = time.time() + 20
            while time.time() < deadline and not panel.available():
                time.sleep(0.3)
            if not panel.available():
                print(f'候选窗状态 socket 不可用：{panel.path}'
                      f'（需要验收构建＋{VALIDATION_MARKER} 私有开关＋重启输入法）')
                panel = None
            else:
                print(f'候选窗状态 socket 已连接：{panel.path}')
        # 输入法进程重启后共享引擎异步就绪：就绪前按键全部透传成 ASCII，
        # 会污染矩阵轮次。稳定等待（socket 真实问答通过）＋额外 1.5 秒。
        time.sleep(1.5)
        for host in hosts:
            for target in TARGETS.get(host, ['default']):
                key = (host, target)
                try:
                    session = make_session(driver, host, target, run_id)
                    session.open()
                    session.focus_target()
                    # 就绪等待：冷启动宿主的窗口标题／前台身份需要时间出现在 AX 里；
                    # 期间重发聚焦（Electron 宿主激活慢），就绪即止；不足时跳过该宿主，
                    # 不重试投递按键。
                    deadline = time.time() + 30
                    last_focus = 0.0
                    while time.time() < deadline:
                        info = driver.ax(op='check', marker=session.guard_marker)
                        ready = (info.get('ok')
                                 and info.get('frontBundle') == session.guard_bundle
                                 and (not session.guard_marker or info.get('markerOk')))
                        if ready:
                            break
                        if time.time() - last_focus > 3.0:
                            session.focus_target()
                            last_focus = time.time()
                        time.sleep(0.3)
                    else:
                        raise HostError(f'宿主就绪超时：前台 {info.get("frontBundle")!r}'
                                        f' 标题 {info.get("title")!r}')
                    sessions[key] = session
                    print(f'宿主就绪：{host}/{target}')
                except HostError as error:
                    skipped.append({'host': host, 'target': target, 'reason': str(error)})
                    print(f'跳过宿主 {host}/{target}：{error}')
        runner = Runner(driver, panel, args.iterations, warmup=args.warmup,
                        evidence=evidence, stop_on_failure=args.stop_on_failure,
                        panel_observation=args.panel_observation)
        for group in plan['groups']:
            session = sessions.get((group['host'], group['target']))
            if session is None:
                continue
            print(f'== {group["id"]} × {runner.iterations} 次 ==', flush=True)
            runner.run_group(session, group)
        # 面板专测：每个宿主 × 每种确认方式一次。
        for (host, target), session in sessions.items():
            if args.caret_probe:
                print(f'== 拼音光标真实窗口核对：{host}/{target} ==', flush=True)
                runner.run_caret_probe(session, shots_dir=args.shots_dir)
            for confirm in CONFIRMATIONS:
                runner.run_panel_check(session, confirm)
        report = {
            'schema': 'gogaku.first-key-matrix.v1',
            'checkedAt': now_iso(),
            'runId': run_id,
            'inputSource': {'id': SOURCE,
                            'installedPath': str(INSTALLED_BINARY),
                            'installedSHA256': sha256_file(INSTALLED_BINARY)},
            'driver': {
                'probeSHA256': sha256_file(driver.temp / 'Gogaku IMK Probe.app/Contents/MacOS/Probe'),
                'axReaderSHA256': sha256_file(driver.ax_binary),
                'pageSHA256': sha256_file(ROOT / 'probes/real-host-test-page.html'),
                'planSHA256': plan['sha256'],
            },
            'panelState': {
                'enabled': panel is not None,
                'socket': args.panel_state_socket if panel is not None else None,
                'protocol': {'transport': 'AF_UNIX/SOCK_STREAM',
                             'request': 'state\\n | metrics\\n | reset\\n | scenario <name>\\n',
                             'stateFields': list(REQUIRED_STATE_FIELDS),
                             'metricsExtra': ['samples'],
                             'samplesFields': ['callbackNs', 'coreNs', 'queueWaitNs', 'coreExecNs',
                                               'hostReadNs', 'markedWriteNs', 'anchorReadNs',
                                               'commitCallNs', 'commitCount', 'hostSelection',
                                               'renderNs', 'firstDisplayNs', 'confirmationHidden',
                                               'visibleAtReturn', 'firstDisplay', 'scenario'],
                             'containsText': False},
                'enableProcedure': {
                    'marker': str(VALIDATION_MARKER),
                    'markerMode': '0600',
                    'logDirectory': str(LOG_DIR),
                    'logDirectoryMode': '0700',
                    'socketMode': '0600',
                    'requires': '验收构建（scripts/build.py --validation）＋重启输入法进程',
                },
            },
            'plan': {k: v for k, v in plan.items() if k != 'groups'},
            'inputLettersEnabled': runner.letters_enabled,
            'groups': runner.groups,
            'panelReports': runner.panel_reports,
            'skipped': skipped,
            'checks': runner.checks,
            'failures': runner.failures,
            'evidence': str(evidence),
        }
        args.report.parent.mkdir(parents=True, exist_ok=True)
        args.report.write_text(json.dumps(report, ensure_ascii=False, indent=2) + '\n')
        print(f'首键回归：{len(runner.checks)} 项检查，失败 {runner.failures} → {args.report}')
        return 1 if runner.failures else 0
    except GuardError as error:
        # 前台身份断言失败：立即停止，不向任何未确认目标投递按键。
        print(f'前台身份断言失败，整轮中止（未投递的按键不再补发）：{error}')
        return 5
    finally:
        for session in list(sessions.values()):
            try:
                session.close()
            except Exception:
                pass
        driver.close()


if __name__ == '__main__':
    raise SystemExit(main())
