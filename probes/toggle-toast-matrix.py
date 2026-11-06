#!/usr/bin/env python3
"""切换提示浮层真实宿主矩阵：模式切换（普通↔学习）后 ToastWindow 是否出现。

只读判定，不做内容断言：
- 每次切换前后读 settings.json 的 preferredMode，确认切换确实发生
  （排除「快捷键没到达输入法」这一类原因）。
- toast-watch 观察输入法进程的 layer=25（statusBar）borderless 窗口：
  ToastWindow.show 只在拿到有效锚点时 orderFrontRegardless，因此
  「模式翻转了但浮层窗口从未出现」即复现用户报告的「有时切换无提示」。

场景（全部用 first_key_regression 的专属窗口／PTY 与前台守卫）：
- probe-idle      探针窗口空字段，无组合
- probe-composing 探针窗口组合中（ni 输入一半）切换
- probe-secure    探针窗口密码字段（SecureEventInput：宿主矩形不可读）
- textedit-idle   TextEdit 专属文档空文档
- terminal-idle   Terminal 专属标签提示符处
- orca-pty-idle   Orca 专属 PTY 提示符处

用法：python3 probes/toggle-toast-matrix.py [--hosts ...] [--channel stable|dev]
报告：docs/validation/toggle-toast-matrix.json
"""
import argparse
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import select
import subprocess
import sys
import tempfile
import time

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / 'probes'))

import first_key_regression as fkr  # noqa: E402

REPORT = ROOT / 'docs/validation/toggle-toast-matrix.json'
MODIFIER_BITS = {'control': 262144, 'shift': 131072, 'option': 524288, 'command': 1048576}


def ime_pid(channel):
    name = 'Gogaku Dev.app' if channel == 'dev' else 'Gogaku.app'
    result = subprocess.run(['pgrep', '-f', f'Input Methods/{name}'],
                            capture_output=True, text=True)
    pids = [int(line) for line in result.stdout.split() if line.strip().isdigit()]
    return pids[0] if pids else None


def read_settings():
    try:
        return json.loads(fkr.SETTINGS_PATH.read_text())
    except (OSError, json.JSONDecodeError):
        return {}


def toggle_action(shortcut):
    action = {'key': shortcut.get('key', 't'),
              'control': False, 'option': False, 'shift': False, 'command': False}
    for name, bit in MODIFIER_BITS.items():
        if int(shortcut.get('modifiers', 0)) & bit:
            action[name] = True
    return action


def compile_toast_watch(workdir):
    binary = workdir / 'toast-watch'
    subprocess.check_call(['swiftc', str(ROOT / 'probes/toast-watch.swift'),
                           '-o', str(binary)], env=fkr.ENV)
    return binary


class MayoiSession(fkr.BaseSession):
    """Mayoi（dev.mayoi.editor）内嵌终端：专属临时文件夹开新窗口。

    用户报告的真实复现场景（Electron 终端，组合外读不到光标矩形）。
    只在窗口标题含本轮标记时注入；收尾关掉自己开的窗口，不碰用户窗口。
    """

    name = 'mayoi'
    bundle = 'dev.mayoi.editor'
    value_view = 'committed_only'
    supports_caret = False

    def open(self):
        self.temp = Path(tempfile.mkdtemp(prefix='gogaku-mayoi-'))
        self.marker = self.temp.name
        subprocess.run(['mayoi', '-n', str(self.temp)], env=fkr.ENV,
                       check=True, timeout=60, cwd=str(ROOT))
        if not self.wait_front():
            # CLI 开窗不保证前置；显式激活该文件夹的窗口再等。
            subprocess.run(['mayoi', str(self.temp)], env=fkr.ENV,
                           check=True, timeout=30, cwd=str(ROOT))
            if not self.wait_front():
                raise fkr.HostError(f'Mayoi 窗口未就绪')
        self.guard_bundle = self.bundle
        self.guard_marker = self.marker
        subprocess.run(['mayoi', 'run', 'view.newTerminal'], cwd=str(self.temp),
                       env=fkr.ENV, check=True, timeout=30)
        time.sleep(1.5)
        return {'window': self.marker}

    def wait_front(self, timeout=12):
        deadline = time.time() + timeout
        while time.time() < deadline:
            info = self.driver.ax(op='check', marker='')
            if (info.get('frontBundle') == self.bundle
                    and self.marker in (info.get('title') or '')):
                return True
            time.sleep(0.5)
        return False

    def close(self):
        try:
            subprocess.run(['mayoi', str(self.temp)], env=fkr.ENV,
                           check=True, timeout=30, cwd=str(ROOT))
            time.sleep(1.0)
            self.assert_front()
            # ⇧⌘W 关闭自己开的窗口；标记守卫确保前台是本轮窗口。
            self.send([[{'key': 'w', 'command': True, 'shift': True}]])
            time.sleep(1.0)
        except (fkr.HostError, fkr.GuardError, subprocess.SubprocessError) as error:
            print(f'[mayoi] 窗口关闭失败，请手动关闭 {self.marker}：{error}', flush=True)

    def focus_target(self):
        subprocess.run(['mayoi', str(self.temp)], env=fkr.ENV,
                       check=True, timeout=30, cwd=str(ROOT))
        if not self.wait_front():
            raise fkr.HostError('Mayoi 窗口无法前置')
        time.sleep(0.5)

    def reset_field(self):
        self.send([[{'key': 'esc'}]])
        self.send([[{'key': 'c', 'control': True}]])

    def read(self):
        return {'value': '', 'committed': None, 'caret': None,
                'caretStatus': 'unverified-terminal-selection-not-readable',
                'marked': None}


class ToastWatch:
    """输入法进程浮层窗口观察：基线后新出现的 layer=25 窗口即切换提示。"""

    def __init__(self, binary, pid, duration):
        self.proc = subprocess.Popen([str(binary), str(pid), str(duration)],
                                     stdout=subprocess.PIPE, text=True, bufsize=1, env=fkr.ENV)
        self.events = []
        self.ready = False
        self.done = False

    def poll(self, timeout):
        deadline = time.time() + timeout
        while time.time() < deadline:
            readable, _, _ = select.select([self.proc.stdout], [], [], 0.05)
            if not readable:
                continue
            line = self.proc.stdout.readline()
            if not line:
                break
            payload = json.loads(line)
            if payload.get('ready'):
                self.ready = True
            elif payload.get('done'):
                self.done = True
            else:
                self.events.append(payload)
            if self.done:
                break
        return self.done

    def wait_ready(self, timeout=5.0):
        deadline = time.time() + timeout
        while time.time() < deadline and not self.ready:
            self.poll(0.2)
        return self.ready

    def summary(self):
        shown = [e for e in self.events if e.get('event') == 'shown']
        return {
            'toastShown': bool(shown),
            'shownCount': len(shown),
            'firstShownMs': shown[0].get('tMs') if shown else None,
            'lifeMs': next((e.get('lifeMs') for e in self.events if e.get('event') == 'hidden'), None),
            'events': self.events,
        }

    def stop(self):
        if self.proc.poll() is None:
            self.proc.kill()


def wait_mode_flip(before, deadline_seconds=2.0):
    deadline = time.time() + deadline_seconds
    while time.time() < deadline:
        mode = read_settings().get('preferredMode')
        if mode and mode != before:
            return mode
        time.sleep(0.1)
    return None


def run_scenario(session, action, watch_binary, pid, label, kind, results,
                 extra_check=None):
    entry = {'scenario': label, 'host': session.name, 'kind': kind,
             'modeBefore': read_settings().get('preferredMode')}
    watch = ToastWatch(watch_binary, pid, 2.5)
    try:
        if not watch.wait_ready():
            raise fkr.HostError('toast-watch 未就绪')
        if kind == 'composing':
            session.send([[{'key': 'n'}, {'key': 'i'}]])
            time.sleep(0.4)
            active = extra_check() if extra_check else None
            entry['compositionActive'] = active
        session.send([[action]])
        entry['modeAfter'] = wait_mode_flip(entry['modeBefore'])
        entry['modeFlipped'] = entry['modeAfter'] is not None
        watch.poll(3.0)
        entry.update(watch.summary())
    except (fkr.HostError, fkr.GuardError) as error:
        entry['error'] = str(error)
    finally:
        watch.stop()
    # 恢复全局模式：同会话上下文再切一次。
    if entry.get('modeFlipped'):
        try:
            session.send([[action]])
            restored = wait_mode_flip(entry['modeAfter'])
            entry['modeRestored'] = restored == entry['modeBefore']
        except (fkr.HostError, fkr.GuardError) as error:
            entry['restoreError'] = str(error)
    results.append(entry)
    print(f"[{label}] modeFlipped={entry.get('modeFlipped')} "
          f"toastShown={entry.get('toastShown')} error={entry.get('error')}",
          flush=True)
    return entry


def write_report(args, results, pid, shortcut):
    missing = [r for r in results if r.get('modeFlipped') and not r.get('toastShown')]
    report = {
        'schema': 'gogaku.toggle-toast-matrix.v1',
        'createdAt': datetime.now(timezone.utc).isoformat(),
        'channel': args.channel,
        'source': args.source,
        'imePid': pid,
        'modeShortcut': shortcut,
        'results': results,
        'missingToastScenarios': [r['scenario'] for r in missing],
    }
    args.report.write_text(json.dumps(report, ensure_ascii=False, indent=2) + '\n')
    print(f"报告：{args.report}")
    print(f"翻转成功但无提示的场景：{report['missingToastScenarios'] or '无'}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--hosts', default='textedit,terminal,orca-pty,mayoi')
    parser.add_argument('--channel', choices=['stable', 'dev'], default='stable')
    parser.add_argument('--source', default=os.environ.get('GOGAKU_SOURCE', fkr.SOURCE))
    parser.add_argument('--report', type=Path, default=REPORT)
    args = parser.parse_args()

    settings = read_settings()
    shortcut = settings.get('modeShortcut', {'key': 't', 'modifiers': 1966080})
    action = toggle_action(shortcut)
    initial_mode = settings.get('preferredMode')
    if initial_mode not in ('normal', 'learning'):
        raise SystemExit(f'settings.json preferredMode 异常：{initial_mode!r}')

    pid = ime_pid(args.channel)   # 新通道首次选中前进程不存在，选中后再等拉起

    run_id = datetime.now().strftime('%Y%m%d%H%M%S')
    driver = fkr.Driver()
    watch_binary = compile_toast_watch(driver.temp)
    session_map = dict(fkr.SESSIONS)
    session_map['mayoi'] = (MayoiSession, ['default'])
    results = []
    probe = fkr.ProbeSession(driver, run_id)
    try:
        driver.build()
        time.sleep(1.0)   # 探针启动激活稳定；过早采集会把前台 guard 记成别的应用

        def probe_state():
            state = driver.ask(op='state')
            marked = state.get('marked') or {}
            return {'marked': marked.get('text', ''), 'raw': state.get('rawText', ''),
                    'text': state.get('text', '')}

        def composing_active():
            info = probe_state()
            return bool(info['marked'])

        def select_source():
            """选源必须在宿主窗口已在前台之后：应用激活会让系统恢复该应用
            记忆的输入源，先选后激活会把刚选的源顶掉（2026-11-06 实测 stable
            顶掉 dev）。激活后仍有异步恢复竞态：选完必须读回 selected，
            不稳定就重试，直到连续两次读回都成立。"""
            nonlocal pid
            last_reply = None
            for _attempt in range(4):
                last_reply = driver.ask(op='select', id=args.source)
                if last_reply.get('status') not in (0, None, '0'):
                    raise SystemExit(f'输入源选择失败（status={last_reply.get("status")}）：'
                                     f'{args.source} 未启用？')
                time.sleep(1.2)
                if self_selected():
                    time.sleep(1.0)
                    if self_selected():
                        if pid is None:
                            deadline = time.time() + 15
                            while time.time() < deadline and pid is None:
                                time.sleep(0.5)
                                pid = ime_pid(args.channel)
                        if pid is None:
                            raise SystemExit(f'选择 {args.source} 后输入法进程仍未拉起'
                                             f'（channel={args.channel}）')
                        return
            raise SystemExit(f'输入源选择不稳定，重试 4 次仍被顶回：{args.source}')

        def self_selected():
            sources = driver.ask(op='sources').get('sources', [])
            chosen = next((s for s in sources if s.get('id') == args.source), None)
            return bool(chosen and chosen.get('selected'))

        def restore_mode():
            """兜底：全局模式与本轮起点不一致时从探针窗口再切一次。"""
            if read_settings().get('preferredMode') == initial_mode:
                return True
            try:
                driver.ask(op='frontApp', id=fkr.PROBE_BUNDLE_ID)
                time.sleep(0.5)
                probe.open()
                probe.assert_front()
                select_source()
                probe.send([[action]])
                return wait_mode_flip(initial_mode, 2.0) == initial_mode
            except (fkr.HostError, fkr.GuardError) as error:
                print(f'模式恢复失败：{error}', flush=True)
                return False

        driver.ask(op='frontApp', id=fkr.PROBE_BUNDLE_ID)
        probe.open()   # 前台稳定后 setMarker，guard pid 才是探针自身
        try:
            driver.ask(op='focus', field=1)
            time.sleep(0.5)
            probe.assert_front()
            select_source()
            probe.send([[{'key': 'a'}]])   # 选源后预热：切换后首键可能被系统吞掉
            time.sleep(0.3)
            probe.reset_field()
            run_scenario(probe, action, watch_binary, pid, 'probe-idle', 'idle', results)
            probe.reset_field()
            run_scenario(probe, action, watch_binary, pid, 'probe-composing', 'composing',
                         results, extra_check=composing_active)
            probe.reset_field()
            state_after_reset = probe_state()
            results[-1]['fieldAfterReset'] = state_after_reset
        finally:
            restore_mode()
            probe.close()

        for host in [h.strip() for h in args.hosts.split(',') if h.strip()]:
            cls = session_map.get(host, (None, []))[0]
            if cls is None:
                print(f'跳过未知宿主：{host}', flush=True)
                continue
            session = cls(driver, run_id)
            try:
                session.open()
            except Exception as error:
                results.append({'scenario': f'{host}-idle', 'host': host,
                                'skipped': True, 'error': str(error)})
                print(f'[{host}] 打开失败，跳过：{error}', flush=True)
                continue
            try:
                session.focus_target()
                session.assert_front()
                select_source()   # 宿主激活会恢复它记忆的输入源，激活后重选
                run_scenario(session, action, watch_binary, pid, f'{host}-idle', 'idle', results)
                session.reset_field()
            except (fkr.HostError, fkr.GuardError) as error:
                results.append({'scenario': f'{host}-idle', 'host': host,
                                'error': str(error)})
                print(f'[{host}] 失败：{error}', flush=True)
            finally:
                restore_mode()
                session.close()
    finally:
        driver.close()
        write_report(args, results, pid, shortcut)
    return 0


if __name__ == '__main__':
    sys.exit(main())
