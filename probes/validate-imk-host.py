#!/usr/bin/env python3
"""真实 IMK 回归；短暂接管焦点和输入源，仅输入合成文字，结束后恢复。

--orca 在当前 Orca 工作区新开 PTY 字节接收终端；从不向已有 agent 终端发送按键。
"""
import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import select
import time
import shlex
import subprocess
import tempfile
import plistlib

ROOT = Path(__file__).resolve().parent.parent
SOURCE = 'org.gogaku.inputmethod.Hans'
ABC = 'com.apple.keylayout.ABC'
ENV = dict(os.environ)
if Path('/Applications/Xcode.app/Contents/Developer').is_dir():
    ENV.setdefault('DEVELOPER_DIR', '/Applications/Xcode.app/Contents/Developer')


def run(*args):
    return subprocess.check_output(args, cwd=ROOT, env=ENV, text=True, timeout=30)


def orca(*args):
    result = json.loads(run('orca', *args, '--json'))
    assert result['ok'], result
    return result['result']


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--orca', action='store_true')
    parser.add_argument('--restore-terminal')
    parser.add_argument('--report', type=Path, default=ROOT / 'docs/validation/imk-host-smoke.json')
    args = parser.parse_args()
    report = {'checkedAt': datetime.now(timezone.utc).isoformat(), 'checks': []}
    binary = Path.home() / 'Library/Input Methods/Gogaku.app/Contents/MacOS/GogakuInput'
    report['installedInputSHA256'] = hashlib.sha256(binary.read_bytes()).hexdigest()
    with tempfile.TemporaryDirectory(prefix='gogaku-imk-') as temp:
        contents = Path(temp) / 'Gogaku IMK Probe.app/Contents'
        (contents / 'MacOS').mkdir(parents=True)
        (contents / 'Info.plist').write_bytes(plistlib.dumps({
            'CFBundleIdentifier': 'org.gogaku.validation.host', 'CFBundleName': 'Gogaku IMK Probe',
            'CFBundleExecutable': 'Probe', 'CFBundlePackageType': 'APPL', 'NSHighResolutionCapable': True,
        }))
        executable = contents / 'MacOS/Probe'
        run('swiftc', str(ROOT / 'probes/imk-regression-host.swift'), '-o', str(executable))
        run('codesign', '--force', '--sign', '-', str(contents.parent))
        with (Path(temp) / 'stderr.log').open('w') as errors:
            process = subprocess.Popen([str(executable)], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                       stderr=errors, text=True, bufsize=1, env=ENV)
            def receive():
                assert select.select([process.stdout], [], [], 10)[0], 'IMK host response timed out'
                line = process.stdout.readline()
                assert line, 'IMK host exited'
                return json.loads(line)
            def command(op, **kwargs):
                process.stdin.write(json.dumps({'op': op, **kwargs}) + '\n')
                process.stdin.flush()
                return receive()
            def keys(codes):
                for code in codes:
                    command('key', code=code, delay=0.1)
                return command('state')
            def check(name, condition, evidence):
                report['checks'].append({'name': name, 'passed': bool(condition), 'evidence': evidence})
                assert condition, (name, evidence)
                print('PASS:', name, flush=True)
            def choose(identifier):
                value = command('select', id=identifier)
                assert value['status'] == 0 and value['source'] == identifier, value
            def toggle_pairs(scope):
                choose(ABC); choose(SOURCE)
                transitions = []
                for _ in range(3):
                    a = command('shortcut')['source']
                    b = command('shortcut')['source']
                    transitions.append([a, b])
                check(scope + '_control_space_both_directions',
                      all(pair == [ABC, SOURCE] for pair in transitions), transitions)

            ready = receive()
            terminal = None
            try:
                toggle_pairs('native')
                command('reset')
                command('key', code=53)  # Esc：清掉切换期可能重复投递的组合
                time.sleep(0.6)  # 重新聚焦后系统 IMK 会话重挂需要时间，立即注入会绕过输入法
                keys([45, 34, 4, 8])
                before = command('state')
                # 输入区字母按规格以 marked text 显示（不算正文）；检查「已确认正文」为空。
                # 本检查必须在任何打字之前（新鲜窗口无锚点残留）。
                check('native_preedit_stays_out_of_host', before['text'] == '', before['rawText'])
                # 冷启动窗口期：输入源进程异步加载词库，期间按键按规格直接交给宿主。
                # 就绪重试：nihc＋空格直到宿主再次出现 你好（最多 8 次，间隔 1 秒）。
                ready_hits = 0
                for attempt in range(8):
                    command('reset')
                    command('key', code=53)
                    keys([49, 51])  # 吸收键
                    keys([45, 34, 4, 8])
                    command('key', code=49)
                    time.sleep(1.0)
                    if command('state')['text'].count('你好') > ready_hits:
                        ready_hits += 1
                        print(f'PASS: input_source_ready (第 {attempt + 1} 次尝试)', flush=True)
                        report['checks'].append({'name': 'input_source_ready', 'passed': True,
                                                 'evidence': f'attempt {attempt + 1}'})
                        break
                else:
                    check('input_source_ready', False, '8 次尝试后仍未上屏')
                # 就绪后字段＝「你好」：空闲空格透传（不重复提交组合，也不产生第二个 你好）
                value = keys([49])
                check('native_space_commits_once',
                      value['text'].count('你好') == 1 and value['text'] in ('你好', '你好 '),
                      {'text': value['text'], 'inserts': value['inserts']})
                # 原文提交（自包含）：reset 后 m＋return → 字段恰为「m」（原样一次）
                command('reset')
                command('key', code=53)
                keys([49, 51])
                value = keys([46, 36])
                check('native_enter_commits_original_once',
                      value['text'].strip() == 'm' and value['text'].count('m') == 1,
                      {'text': value['text'], 'inserts': value['inserts']})
                keys([45, 34])
                command('focus', field=2)
                value = keys([49])
                check('native_field_change_revokes_old_commit',
                      value['text'].strip() == 'm' and value['text'].count('m') == 1 and value['second'] == ' ',
                      {'first': value['text'], 'second': value['second']})
                command('reset')
                command('key', code=53)  # Esc 清组合（程序化 reset 后的组合残留）
                keys([49, 51])  # 吸收键：重复投递落在 space/backspace 上，净零
                command('set', text='left old right', selection=[5, 3])
                value = keys([46, 36])
                check('native_original_replaces_selected_text_once', value['text'] == 'left m right' and value['inserts'] == 1,
                      {'text': value['text'], 'inserts': value['inserts']})
                command('reset')
                command('key', code=53)  # Esc 清组合（程序化 reset 后的组合残留）
                keys([49, 51])  # 吸收键：重复投递落在 space/backspace 上，净零
                value = command('burst', codes=[45, 34, 36])
                # 注入重复投递会使 inserts 计数不可靠；文本恰为 'ni' 才是不变量。
                check('native_rapid_original_preserves_accepted_keys', value['text'] == 'ni',
                      {'text': value['text'], 'inserts': value['inserts']})
                command('reset')
                command('key', code=53)  # Esc 清组合（程序化 reset 后的组合残留）
                keys([49, 51])  # 吸收键：重复投递落在 space/backspace 上，净零
                value = command('burst', codes=[46, 36])
                check('native_rapid_single_original_commits_once', value['text'] == 'm',
                      {'text': value['text'], 'inserts': value['inserts']})
                command('reset')
                value = keys([45, 34, 18])
                first = value['text']
                check('native_digit_selects_first_page_candidate', bool(first) and first != 'ni', first)
                command('reset')
                value = keys([45, 34, 47, 18])
                paged = value['text']
                check('native_period_pages_down_before_digit',
                      bool(paged) and paged != first and '.' not in paged, paged)
                command('reset')
                value = keys([45, 34, 47, 43, 18])
                check('native_comma_pages_back_to_first', value['text'] == first, value['text'])
                command('reset')
                command('key', code=53)  # Esc 清组合（程序化 reset 后的组合残留）
                keys([49, 51])  # 吸收键：重复投递落在 space/backspace 上，净零
                command('set', text='abcd', selection=[4, 0])
                value = keys([51])
                check('native_backspace_passes_through_without_composition',
                      value['text'] == 'abc' and value['inserts'] == 0,
                      {'text': value['text'], 'inserts': value['inserts']})
                command('reset')
                command('key', code=53)  # Esc 清组合
                keys([49, 51])  # 吸收键 ×2（重复投递落点每次不同）
                keys([49, 51])
                keys([45, 34, 4, 8])
                before = command('state')
                value = keys([51, 51, 49])
                # 注入重复投递下 inserts 计数不可靠；不变量＝编辑组合后提交「你」。
                check('native_backspace_edits_composition_then_commits',
                      before['text'] == '' and value['text'] == '你',
                      {'before': before['text'], 'text': value['text'], 'inserts': value['inserts']})
                command('reset')
                command('key', code=53)  # Esc 清组合（程序化 reset 后的组合残留）
                keys([49, 51])  # 吸收键：重复投递落在 space/backspace 上，净零
                if args.orca:
                    received = Path(temp) / 'received.bin'
                    receiver_command = 'python3 ' + shlex.quote(str(ROOT / 'probes/imk-terminal-receiver.py')) + ' ' + shlex.quote(str(received))
                    result = orca('terminal', 'create', '--worktree', 'path:' + str(ROOT),
                                  '--title', 'Gogaku IMK regression', '--command', receiver_command)
                    terminal = result['terminal']['handle']
                    orca('terminal', 'switch', '--terminal', terminal)
                    value = command('frontApp', id='com.stablyai.orca')
                    assert value['front'] == 'com.stablyai.orca', value
                    toggle_pairs('orca_terminal')
                    assert received.exists(), 'PTY fixture did not become ready'
                    def payload():
                        return received.read_bytes()
                    assert payload() == b'', 'PTY fixture must start empty'
                    keys([45, 34, 4, 8])
                    check('orca_preedit_stays_out_of_terminal', payload() == b'', 'no PTY bytes before confirmation')
                    keys([49])
                    data = payload()
                    check('orca_space_commits_once', data == '你好'.encode(), data.hex())
                    keys([46, 36])
                    data = payload()
                    # 注入重复投递可能把 return 透传成尾部 \r；不变量＝原文 m 恰好一次。
                    check('orca_enter_commits_original_once',
                          data in ('你好m'.encode(), '你好m\r'.encode()), data.hex())
                    keys([45, 34])
                    a = command('shortcut')['source']
                    b = command('shortcut')['source']
                    keys([45, 34, 4, 8, 49])
                    data = payload()
                    # 注入重复投递会插入散落 \r；不变量＝去除 \r 后恰为 你好m你好。
                    clean = data.replace(b'\r', b'')
                    check('orca_source_change_cancels_old_composition',
                          [a, b] == [ABC, SOURCE] and clean == '你好m你好'.encode(), data.hex())
            finally:
                if terminal:
                    orca('terminal', 'close', '--terminal', terminal)
                if args.restore_terminal:
                    orca('terminal', 'switch', '--terminal', args.restore_terminal)
                try:
                    if ready.get('originalApplication'):
                        command('frontApp', id=ready['originalApplication'])
                    choose(ready['originalSource'])
                    command('quit')
                    process.wait(timeout=5)
                finally:
                    if process.poll() is None:
                        process.terminate(); process.wait(timeout=5)
                    args.report.parent.mkdir(parents=True, exist_ok=True)
                    args.report.write_text(json.dumps(report, ensure_ascii=False, indent=2) + '\n')
    print('Report:', args.report)


if __name__ == '__main__':
    main()
