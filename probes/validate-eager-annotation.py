#!/usr/bin/env python3
"""学习中→英预译注释真实宿主回归（2026-11-06 防抖加固轮专项）。

场景＝用户反馈「输入停止了但译文不出来」：
1. Gogaku Dev 输入源＋学习模式中→英；
2. 探针专属窗口内逐键输入 nihao（键间约 0.2s，防抖期间不断重排）；
3. 完全停止输入，轮询等待防抖到期＋后端时延；
4. 捕获 Gogaku 候选窗并 Vision OCR：断言出现与键入拼音不同的英文词（注释）；
5. 再空闲 3s 复拍：注释仍在（渲染单次机会死端的空闲回归口径）。

焦点与恢复：只在探针自身窗口注入按键（每次投递经宿主前台守卫），结束后
恢复原输入源并退出。模式／方向切换用设置里的真实快捷键（System Events 和弦）。
报告与面板截图写入 docs/validation/verify/eager-annotation-*。
"""
import argparse
import json
import os
import re
import select
import subprocess
import tempfile
import plistlib
import time
from datetime import datetime, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SOURCE = 'org.gogaku.inputmethod.dev.Hans'
ABC = 'com.apple.keylayout.ABC'
DETECT_PINYIN = 'nihao'          # 就绪／模式探测用（译文会入缓存）
LETTER_CODES = {'a': 0, 'b': 11, 'c': 8, 'd': 2, 'e': 14, 'f': 3, 'g': 5, 'h': 4, 'i': 34,
                'j': 37, 'k': 40, 'l': 37, 'm': 46, 'n': 45, 'o': 31, 'p': 35, 'q': 12,
                'r': 15, 's': 1, 't': 17, 'u': 32, 'v': 9, 'w': 13, 'x': 7, 'y': 16, 'z': 6}
ENV = dict(os.environ)
if Path('/Applications/Xcode.app/Contents/Developer').is_dir():
    ENV.setdefault('DEVELOPER_DIR', '/Applications/Xcode.app/Contents/Developer')


def run(*args, timeout=60):
    return subprocess.check_output(args, cwd=ROOT, env=ENV, text=True, timeout=timeout)


def load_shortcuts():
    settings = json.loads((Path.home() / 'Library/Application Support/Gogaku/settings.json').read_text())
    def decode(entry):
        modifiers = entry.get('modifiers', 0)
        flags = []
        if modifiers & 0x20000: flags.append('shift')
        if modifiers & 0x40000: flags.append('control')
        if modifiers & 0x80000: flags.append('option')
        if modifiers & 0x100000: flags.append('command')
        return entry['key'], flags
    return decode(settings['modeShortcut']), decode(settings['directionShortcut'])


def chord_probe(command, key_id, flags):
    """探针宿主内显式 flags 的平衡和弦（System Events 和弦会留悬挂修饰态）。"""
    code = LETTER_CODES.get(key_id)
    if code is None:
        raise SystemExit(f'快捷键 {key_id!r} 不在字母键码表内，扩展 LETTER_CODES')
    command('chord', code=code, modifiers=list(flags))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--report-dir', type=Path, default=ROOT / 'docs/validation/verify')
    parser.add_argument('--idle-hold', type=float, default=3.0)
    parser.add_argument('--pinyin', default='tianqi',
                        help='场景拼音（独立于探测串，避开上一轮已入缓存的译文）')
    args = parser.parse_args()
    stamp = time.strftime('%Y%m%d-%H%M%S')
    out_dir = args.report_dir / f'eager-annotation-{stamp}'
    out_dir.mkdir(parents=True, exist_ok=True)
    report = {'checkedAt': datetime.now(timezone.utc).isoformat(), 'source': SOURCE,
              'pinyin': args.pinyin, 'detectPinyin': DETECT_PINYIN, 'checks': [], 'artifacts': {}}

    (mode_key, mode_flags), (direction_key, direction_flags) = load_shortcuts()
    report['modeShortcut'] = {'key': mode_key, 'flags': mode_flags}
    report['directionShortcut'] = {'key': direction_key, 'flags': direction_flags}

    def check(name, passed, evidence):
        report['checks'].append({'name': name, 'passed': bool(passed), 'evidence': evidence})
        print(f"{'PASS' if passed else 'FAIL'}: {name} {json.dumps(evidence, ensure_ascii=False)[:300]}", flush=True)
        return passed

    compiled = []
    for script in ('probes/imk-window-list.swift', 'probes/panel-ocr.swift'):
        binary = out_dir / (Path(script).stem + '.bin')
        run('swiftc', script, '-o', str(binary))
        compiled.append(binary)

    def gogaku_windows(dev_pid, all_windows=False):
        args = [str(compiled[0])]
        if all_windows:
            args.append('--all')
        raw = run(*args, timeout=30)
        rows = []
        for line in raw.splitlines():
            # 行格式：number pid owner… layer=L x y w h（owner 可能含空格）。
            matched = re.match(r'(\d+) (\d+) .*layer=(-?\d+) (\d+) (\d+) (\d+) (\d+)$', line)
            if matched:
                number, pid = int(matched.group(1)), int(matched.group(2))
                bounds = tuple(int(matched.group(i)) for i in range(4, 8))
                rows.append({'id': number, 'pid': pid, 'bounds': bounds})
        return [r for r in rows if r['pid'] == dev_pid and r['bounds'][2] > 40]

    LATIN = re.compile(r'[A-Za-z]{2,}')
    CJK = re.compile(r'[\u4e00-\u9fff]')

    def ocr(window_id, tag):
        png = out_dir / f'panel-{tag}.png'
        result = subprocess.run(['screencapture', '-x', '-o', '-l', str(window_id), str(png)],
                                capture_output=True, text=True)
        if result.returncode != 0 or not png.exists():
            return None, None
        lines = [line for line in run(str(compiled[1]), str(png), timeout=120).splitlines() if line.strip()]
        return lines, png

    typed = args.pinyin

    def annotation_in(lines):
        """注释判据：面板内出现英文词，且不是场景拼音的字母（面板预编辑会
        显示场景拼音本身）。面板窗口已按窗口裁剪，杂讯有限。"""
        words = set()
        for line in lines or []:
            for word in LATIN.findall(line):
                low = word.lower()
                if low != typed and low not in typed:
                    words.add(low)
        return sorted(words)

    with tempfile.TemporaryDirectory(prefix='gogaku-eager-') as temp:
        contents = Path(temp) / 'Gogaku Eager Probe.app/Contents'
        (contents / 'MacOS').mkdir(parents=True)
        (contents / 'Info.plist').write_bytes(plistlib.dumps({
            'CFBundleIdentifier': 'org.gogaku.validation.eager', 'CFBundleName': 'Gogaku Eager Probe',
            'CFBundleExecutable': 'Probe', 'CFBundlePackageType': 'APPL', 'NSHighResolutionCapable': True,
        }))
        executable = contents / 'MacOS/Probe'
        run('swiftc', str(ROOT / 'probes/imk-regression-host.swift'), '-o', str(executable))
        run('codesign', '--force', '--sign', '-', str(contents.parent))
        with (Path(temp) / 'stderr.log').open('w') as errors:
            process = subprocess.Popen([str(executable)], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                       stderr=errors, text=True, bufsize=1, env=ENV)

            def receive():
                assert select.select([process.stdout], [], [], 15)[0], 'IMK host response timed out'
                return json.loads(process.stdout.readline())

            probe_bundle = 'org.gogaku.validation.eager'
            guard = {'bundle': probe_bundle, 'marker': stamp}

            def command(op=None, **request):
                if op is not None:
                    request['op'] = op
                if op in ('key', 'chord'):
                    request['guard'] = guard
                process.stdin.write(json.dumps(request) + '\n')
                process.stdin.flush()
                result = receive()
                if result.get('guardBlocked'):
                    raise SystemExit(f'{op} 被前台守卫拦截（front={result.get("front")}）；'
                                     '停止注键，人工确认前台后重试')
                return result

            ready = receive()
            original_source = ready.get('originalSource') or ABC
            report['originalSource'] = original_source
            command('setMarker', marker=stamp)

            def ensure_source(tag):
                """源选择不保持（曾回跳 stable，两端快捷键相同会互相误触）：
                每阶段前断言当前源＝dev，不对则重选并复查。"""
                for _ in range(3):
                    command('select', id=SOURCE)
                    time.sleep(0.6)
                    current = command('state')['source']
                    if current == SOURCE:
                        return True
                    report.setdefault('sourceBounces', []).append({'at': tag, 'saw': current})
                return False

            def alive_after():
                """管线存活 sanity：一个字母应产生 marked 文本，否则修饰键悬挂。
                返回是否存活（组合由调用方 esc 清理）。"""
                command('key', code=LETTER_CODES['n'])
                time.sleep(0.5)
                marked = command('state').get('marked') or {}
                command('key', code=53)
                return (marked.get('length') or 0) > 0

            if not check('dev_source_selected', ensure_source('start'), SOURCE):
                finish_failure(report, out_dir, process, original_source, command)
                return
            command('reset')
            command('key', code=53)
            time.sleep(0.8)

            # 就绪探测：冷启动窗口期按键会直通宿主；nihao＋空格直到正文非空。
            # 就绪＋模式归位一体决策树（上一轮残留的模式／方向不可预知）：
            # committed 英文词＝学习中→英就绪；CJK＝普通（切模式）；恒空且
            # marked 有字母＝英→中缓冲（Enter 提交中文验证，切方向）。
            committed_sample = ''
            observations = []
            for attempt in range(8):
                ensure_source(f'ready-{attempt}')
                command('reset')
                command('key', code=53)
                for code in [LETTER_CODES[c] for c in DETECT_PINYIN]:
                    command('key', code=code)
                command('key', code=49)  # space
                time.sleep(4.5)
                state = command('state')
                committed_sample = state['text'].strip()
                marked_text = (state.get('marked') or {}).get('text') or ''
                if committed_sample and LATIN.search(committed_sample) \
                        and committed_sample.lower() != DETECT_PINYIN:
                    break
                action = 'done'
                if committed_sample and CJK.search(committed_sample):
                    action = 'mode'
                    chord_probe(command, mode_key, mode_flags)
                elif not committed_sample and marked_text.strip():
                    command('key', code=36)  # Enter：en→zh 提交中文译文
                    time.sleep(1.5)
                    state = command('state')
                    committed_sample = state['text'].strip()
                    if committed_sample and CJK.search(committed_sample):
                        action = 'direction'
                        chord_probe(command, direction_key, direction_flags)
                    elif committed_sample.lower() == DETECT_PINYIN:
                        action = 'zh2en-slow-enter'   # 中→英原编码上屏：方向已对
                        break
                elif not committed_sample:
                    action = 'alive-check'
                    if not alive_after():
                        action = 'dead-pipeline'
                observations.append({'attempt': attempt, 'committed': committed_sample,
                                     'marked': marked_text, 'action': action})
                time.sleep(0.8)
            report['readyObservations'] = observations
            committed_sample = committed_sample.strip()
            if not check('input_source_ready', bool(committed_sample) and LATIN.search(committed_sample)
                         and committed_sample.lower() != DETECT_PINYIN, committed_sample):
                finish_failure(report, out_dir, process, original_source, command)
                return

            # 模式归位：正文是英文词→学习中→英；是「你好」→普通模式（切模式）；
            # 是原样拼音→英→中英文缓冲（切方向）。最多两轮，每轮带完整状态与截图。
            latin = LATIN.findall(committed_sample)
            for fix_round in range(2):
                if latin:
                    break
                ensure_source(f'mode-fix-{fix_round}')
                if CJK.search(committed_sample):
                    chord_probe(command, mode_key, mode_flags)
                else:
                    chord_probe(command, direction_key, direction_flags)
                time.sleep(1.0)
                alive = alive_after()
                report.setdefault('pipelineAlive', []).append({'round': fix_round, 'alive': alive})
                command('reset')
                command('key', code=53)
                for code in [LETTER_CODES[c] for c in DETECT_PINYIN]:
                    command('key', code=code)
                command('key', code=49)
                time.sleep(3.5)
                state = command('state')
                committed_sample = state['text'].strip()
                latin = LATIN.findall(committed_sample)
                if not latin:
                    snapshot_mode_evidence(report, out_dir, ocr, gogaku_windows, dev_input_pid(),
                                           f'mode-fix-{fix_round}')
                report.setdefault('modeFixRounds', []).append(
                    {'round': fix_round, 'committed': committed_sample,
                     'marked': state.get('marked'), 'rawText': state.get('rawText'),
                     'inserts': state.get('inserts'), 'source': state.get('source')})
            is_learning = bool(LATIN.findall(committed_sample)) and committed_sample.lower() != DETECT_PINYIN
            if not check('learning_mode_active', is_learning,
                         {'committed': committed_sample, 'modeFixRounds': report.get('modeFixRounds')}):
                finish_failure(report, out_dir, process, original_source, command)
                return

            # ── 专项场景：逐键输入→完全停止→注释出现──
            ensure_source('scenario')
            command('reset')
            command('key', code=53)
            time.sleep(0.4)
            dev_pid = dev_input_pid()
            if dev_pid is None:
                check('dev_process_running', False, 'pgrep 未找到 Gogaku Dev 输入法进程')
                finish_failure(report, out_dir, process, original_source, command)
                return
            report['devInputPid'] = dev_pid
            for code in [LETTER_CODES[c] for c in typed]:
                command('key', code=code)   # 每键 0.2s 节奏，防抖期不断重排
            # 完全停止输入；轮询候选窗 OCR 直到出现英文注释（或超时）。
            deadline = time.time() + 12.0
            best_lines, best_png = None, None
            attempt = 0
            while time.time() < deadline:
                attempt += 1
                for window in gogaku_windows(dev_pid):
                    lines, png = ocr(window['id'], f'poll{attempt}')
                    if lines is None:
                        continue
                    best_lines, best_png = lines, best_png or png
                    has_panel = len(CJK.findall(''.join(lines))) >= 2
                    words = annotation_in(lines)
                    if has_panel and words:
                        best_png = png
                        report['annotationWords'] = words
                        report['panelOcr'] = lines
                        report['artifacts']['panelPoll'] = str(png)
                        if check('annotation_appears_after_idle', True,
                                 {'attempt': attempt, 'words': words, 'ocr': lines}):
                            idle_hold_ok(report, args, compiled, gogaku_windows, dev_pid, ocr, check,
                                         lambda: command('state'))
                            cleanup(process, original_source, command)
                            write_report(report, out_dir)
                            return
                        break
                time.sleep(0.8)
            report['panelOcr'] = best_lines
            if best_png:
                report['artifacts']['panelLast'] = str(best_png)
            check('annotation_appears_after_idle', False,
                  {'attempts': attempt, 'lastOcr': best_lines})
            finish_failure(report, out_dir, process, original_source, command)


def snapshot_mode_evidence(report, out_dir, ocr, gogaku_windows, dev_pid, tag):
    """模式归位失败时抓面板窗口截图，供事后肉眼归因。"""
    for window in gogaku_windows(dev_pid or 0):
        lines, png = ocr(window['id'], tag)
        if png:
            report.setdefault('artifacts', {})[f'{tag}-w{window["id"]}'] = str(png)


def dev_input_pid():
    result = subprocess.run(['pgrep', '-f', 'Gogaku Dev.app/Contents/MacOS/GogakuInput'],
                            capture_output=True, text=True)
    pids = [int(p) for p in result.stdout.split()]
    return pids[0] if pids else None


def idle_hold_ok(report, args, compiled, gogaku_windows, dev_pid, ocr, check, state):
    """空闲保持：注释渲染后继续闲置，注释不得消失（单次渲染机会死端口径）。
    面板窗口若从屏上消失，用离屏窗口列表与宿主 marked 状态区分：
    组合还在＋窗口停在离屏位＝面板被藏；marked 已清＝组合被宿主取消（环境噪声）。"""
    time.sleep(args.idle_hold)
    held = False
    evidence = {}
    for window in gogaku_windows(dev_pid):
        lines, png = ocr(window['id'], 'idlehold')
        if lines is None:
            continue
        words = annotation_in(lines)
        has_panel = len(CJK.findall(''.join(lines))) >= 2
        evidence = {'ocr': lines, 'words': words, 'png': str(png) if png else None}
        if has_panel and words:
            held = True
            report['artifacts']['panelIdleHold'] = str(png)
            break
    if not held:
        offscreen = [w for w in gogaku_windows(dev_pid, all_windows=True) if w['bounds'][0] < -5000]
        marked = (state() or {}).get('marked') or {}
        evidence['offscreenWindows'] = len(offscreen)
        evidence['markedAfterIdle'] = marked
    check('annotation_survives_idle_hold', held, evidence)


def finish_failure(report, out_dir, process, original_source, command):
    try:
        command('key', code=53)
        cleanup(process, original_source, command)
    except Exception:
        pass
    write_report(report, out_dir)
    raise SystemExit(1)


def cleanup(process, original_source, command):
    try:
        command('select', id=original_source)
        command('quit')
    except Exception:
        pass
    try:
        process.wait(timeout=5)
    except Exception:
        process.kill()


def write_report(report, out_dir):
    path = out_dir / 'report.json'
    path.write_text(json.dumps(report, ensure_ascii=False, indent=2) + '\n')
    print(f'report: {path}', flush=True)


if __name__ == '__main__':
    main()
