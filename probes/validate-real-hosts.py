#!/usr/bin/env python3
"""真实宿主严格回归：TextEdit／Chrome（textarea＋contenteditable）／Safari／Terminal／Orca PTY。

与旧版的差别（都是安全与判定口径的修正，不是功能扩张）：
1. 只操作本次运行创建的专属窗口／文档／PTY。旧版收尾会执行
   「close every document saving no」，把用户所有 TextEdit 文档一起关掉；
   新版只关本轮新建的那一份文档／窗口。
2. 每次投递按键前强断言前台应用身份与专属测试目标身份（窗口标题含本轮唯一
   标记）。断言失败即停止整轮，不向任何未确认的应用注入按键。
3. 判定一律精确相等（正文逐字比对）。旧版 common_text_checks 对丢字会重试，
   并用「包含／计数」做宽松断言，重试会把偶发丢字掩盖成通过；新版失败即记
   证据、退出码非零，不重试。
4. 旧版的程序化输入源切换伪影（切换后首个注入按键可能被系统吞掉）由探针自身
   窗口承担：输入源切换只在探针窗口做一次，随后每组有独立预热轮次（预热结果
   单独记录，不计入矩阵轮次，也不用于重试失败样本）。

首键立即输入矩阵由 probes/first_key_regression.py 提供（--first-key 开启，
默认开启），本脚本负责宿主准备、安全守卫与严格场景集。

用法：python3 probes/validate-real-hosts.py [--hosts ...] [--iterations N]
报告：docs/validation/real-host-matrix.json
"""
import argparse
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import sys
import time

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / 'probes'))

import first_key_regression as fkr  # noqa: E402  （探针共享层：驱动、宿主会话、模型）

SOURCE = fkr.SOURCE
DEFAULT_HOSTS = 'probe,textedit,chrome,safari,terminal,orca-pty'
# Spotlight／Raycast 本轮不跑：环境限制与注入安全都无法保证，不做无保护注入。
EXCLUDED_HOSTS = {'spotlight', 'raycast'}

COMPOSITION = fkr.COMPOSITION
COMPOSITION_LETTERS = list(COMPOSITION)


def letters_action():
    return [{'key': letter} for letter in COMPOSITION_LETTERS]


def shift_action():
    return [{'modifier': 'shift', 'hold': 0.05}]


def both(value, caret, **extra):
    """两种宿主视图（可见／不可见输入区字母）下期望相同的场景。"""
    entry = {'value': value, 'caret': caret}
    entry.update(extra)
    return {'marked_visible': dict(entry), 'committed_only': dict(entry)}


# 严格场景：每个场景只描述「按键序列」与「精确期望」。
# steps 里的每一项是一次 combo 投递（一次守卫检查）；项与项之间是宿主原生节奏。
# expect 按宿主视图给期望：marked_visible＝宿主文本含输入区字母，
# committed_only＝组合未上屏时宿主文本仍为空。
SCENARIOS = [
    {'id': 'combo-punctuation', 'label': '组合中标点一次上屏（nihc＋;）',
     'steps': [letters_action(), [{'key': ';'}]], 'expect': both('你好；', 3)},
    {'id': 'idle-comma', 'label': '无组合逗号按标点表（nihc 空格后 ,）',
     'steps': [letters_action(), [{'key': 'space'}], [{'key': ','}]],
     'expect': both('你好，', 3)},
    {'id': 'idle-period', 'label': '无组合句号按标点表（nihc 空格后 .）',
     'steps': [letters_action(), [{'key': 'space'}], [{'key': '.'}]],
     'expect': both('你好。', 3)},
    {'id': 'capital-space', 'label': '单独大写字母加空格原样上屏',
     'steps': [[{'key': 'm', 'shift': True}], [{'key': 'space'}]],
     'expect': both('M', 1)},
    {'id': 'esc-cancel', 'label': 'Esc 取消组合不残留',
     'steps': [letters_action(), [{'key': 'esc'}]], 'expect': both('', 0)},
    {'id': 'rapid-commit', 'label': '连续输入 nihc＋空格一次提交',
     'steps': [[{'key': letter} for letter in COMPOSITION_LETTERS] + [{'key': 'space'}]],
     'expect': both('你好', 2)},
    {'id': 'shift-in-combo', 'label': '组合中 Shift 单击上屏原编码',
     'steps': [letters_action(), shift_action()], 'expect': both('nihc', 4)},
    {'id': 'shift-then-english', 'label': '组合中 Shift 后进英文直输（nihc→Shift→abc.）',
     'steps': [letters_action(), shift_action(),
               [{'key': 'a'}, {'key': 'b'}, {'key': 'c'}, {'key': '.'}]],
     'expect': both('nihcabc.', 8)},
    {'id': 'shift-back-to-chinese', 'label': '临时英文 Shift 切回中文继续输入',
     'steps': [letters_action(), shift_action(), shift_action(),
               letters_action(), [{'key': 'space'}]],
     'expect': both('nihc你好', 6)},
    {'id': 'marked-letters', 'label': '输入区字母与光标（组合中未上屏）',
     'steps': [letters_action()],
     'expect': {'marked_visible': {'value': 'nihc', 'caret': 4, 'marked': 'nihc', 'committed': ''},
                'committed_only': {'value': '', 'caret': 0}}},
    {'id': 'marked-clear', 'label': '确认后输入区字母被清除',
     'steps': [letters_action(), [{'key': 'space'}]],
     'expect': {'marked_visible': {'value': '你好', 'caret': 2, 'marked': '', 'committed': '你好'},
                'committed_only': {'value': '你好', 'caret': 2}}},
]


class StrictChecks:
    def __init__(self):
        self.results = []
        self.failures = 0

    def check(self, ok, what, detail=''):
        self.results.append({'check': what, 'ok': bool(ok), 'detail': str(detail)[:400],
                             'at': datetime.now(timezone.utc).isoformat()})
        print(('  ok   ' if ok else '  FAIL') + f' {what}' +
              (f'（{str(detail)[:140]}）' if detail else ''), flush=True)
        if not ok:
            self.failures += 1
        return ok


def run_scenarios(session, checks, label, letters_enabled=True):
    """严格场景集：精确相等判定，失败不重试。"""
    view = session.effective_view(letters_enabled)
    for scenario in SCENARIOS:
        expectation = scenario['expect'].get(view)
        if scenario['id'] == 'marked-letters' and view == 'marked_visible':
            try:
                settings = json.loads(fkr.SETTINGS_PATH.read_text())
            except (OSError, json.JSONDecodeError):
                settings = {}
            marked = "ni'hao" if settings.get('fullPinyinPreedit', True) else COMPOSITION
            expectation = {'value': marked, 'caret': len(marked), 'marked': marked, 'committed': ''}
        if expectation is None:
            checks.check(True, f'{label}: {scenario["label"]}（该宿主视图无对应期望，跳过）')
            continue
        try:
            session.reset_field()
            for step in scenario['steps']:
                session.send(step)
            observed = session.read()
        except fkr.GuardError as error:
            checks.check(False, f'{label}: {scenario["label"]}', f'前台身份断言失败：{error}')
            raise
        except fkr.HostError as error:
            checks.check(False, f'{label}: {scenario["label"]}', f'宿主读取失败：{error}')
            continue
        problems = []
        if observed.get('value') != expectation['value']:
            problems.append(f'正文不符：期望 {expectation["value"]!r}，实际 {observed.get("value")!r}')
        caret = observed.get('caret')
        caret_status = observed.get('caretStatus') or ('measured' if caret is not None else 'unverified')
        # 光标只在宿主可读真实选区时比对；读不到的宿主明确记未验证，
        # 不用字符串长度冒充，也不把「跳过」当通过。
        if caret_status == 'measured' and caret != expectation['caret']:
            problems.append(f'光标不符：期望 {expectation["caret"]}，实际 {caret}')
        note = '' if caret_status == 'measured' else f'；光标未验证（{caret_status}）'
        if 'committed' in expectation and observed.get('committed') is not None \
                and observed.get('committed') != expectation['committed']:
            problems.append(f'已确认正文不符：期望 {expectation["committed"]!r}，'
                            f'实际 {observed.get("committed")!r}')
        if session.supports_marked and 'marked' in expectation:
            if (observed.get('marked') or '') != expectation['marked']:
                problems.append(f'输入区字母不符：期望 {expectation["marked"]!r}，'
                                f'实际 {observed.get("marked")!r}')
        checks.check(not problems, f'{label}: {scenario["label"]}{note}',
                     '；'.join(problems) if problems else json.dumps(
                         {'value': observed.get('value'), 'caret': observed.get('caret')},
                         ensure_ascii=False))


def main():
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--hosts', default=DEFAULT_HOSTS,
                        help='逗号分隔宿主；本轮不含 spotlight／raycast')
    parser.add_argument('--iterations', type=int, default=200, help='首键矩阵每组轮次')
    parser.add_argument('--warmup', type=int, default=2, help='每组预热轮次（不计入矩阵）')
    parser.add_argument('--panel-state-socket', default=str(fkr.DEFAULT_SOCKET),
                        help='候选窗状态 socket 路径')
    parser.add_argument('--no-panel-state', action='store_true', help='不做候选窗状态判定')
    parser.add_argument('--enable-validation', action='store_true',
                        help='创建私有开关并重启输入法（启用验收状态接口）')
    parser.add_argument('--no-first-key', action='store_true', help='不跑首键立即输入矩阵')
    parser.add_argument('--panel-observation', type=float, default=2.0,
                        help='候选窗未重弹观察窗口（秒）')
    parser.add_argument('--stop-on-failure', action='store_true', help='首个失败即停止')
    parser.add_argument('--report', type=Path, default=ROOT / 'docs/validation/real-host-matrix.json')
    parser.add_argument('--evidence', type=Path, default=None, help='逐轮证据 JSONL')
    parser.add_argument('--chrome-path', default='/Applications/Google Chrome.app')
    args = parser.parse_args()

    hosts = [h.strip() for h in args.hosts.split(',') if h.strip()]
    for host in hosts:
        if host in EXCLUDED_HOSTS:
            parser.error(f'{host} 本轮不跑（不做无保护注入）')
        if host not in fkr.SESSIONS:
            parser.error(f'未知宿主：{host}（可用：{",".join(fkr.HOST_ORDER)}）')

    if args.enable_validation:
        marker = fkr.enable_validation_monitor()
        print(f'已创建验收开关：{marker}（已重启输入法进程）')

    run_id = f'{int(time.time())}{os.getpid() % 10000:04d}'
    checks = StrictChecks()
    driver = fkr.Driver()
    sessions = {}
    skipped = []
    matrix_report = None
    panel = None if args.no_panel_state else fkr.PanelStateClient(args.panel_state_socket)
    try:
        ready = driver.build()
        print(f'探针宿主已启动（pid {ready.get("pid")}）')
        # 输入源切换只在探针自身窗口做一次（可靠路径）。
        state = driver.ask(op='select', id=SOURCE)
        if state.get('source') != SOURCE:
            print(f'输入源切换失败：当前 {state.get("source")!r}'
                  f'（Gogaku 需要用户先在系统设置里启用该输入源）')
            return 2
        if panel is not None:
            deadline = time.time() + 15
            while time.time() < deadline and not panel.available():
                time.sleep(0.3)
            if not panel.available():
                print(f'候选窗状态 socket 不存在：{panel.path}（本轮不做面板状态判定）')
                panel = None
            else:
                print(f'候选窗状态 socket 已连接：{panel.path}')
        for host in hosts:
            for target in fkr.TARGETS.get(host, ['default']):
                key = (host, target)
                session = None
                try:
                    session = fkr.make_session(driver, host, target, run_id)
                    session.open()
                    # BrowserSession.focus_target 需要目标字段（textarea／
                    # contenteditable 分组各自聚焦），其余会话签名无参。此前
                    # 一律无参调用，进入浏览器宿主即 TypeError 崩溃（2026-11-10
                    # host 档实测暴露；基线以来浏览器路径从未跑通）。
                    if isinstance(session, fkr.BrowserSession):
                        session.focus_target(target)
                    else:
                        session.focus_target()
                    sessions[key] = session
                    print(f'宿主就绪：{host}/{target}')
                except fkr.HostError as error:
                    skipped.append({'host': host, 'target': target, 'reason': str(error)})
                    print(f'跳过宿主 {host}/{target}：{error}')
                    fkr.close_quietly(session)
        # 严格场景集。
        letters_enabled = fkr.input_letters_enabled()
        for (host, target), session in sessions.items():
            print(f'== 严格场景 {host}/{target} ==')
            run_scenarios(session, checks, f'{host}/{target}', letters_enabled)
        # 首键立即输入矩阵。
        if not args.no_first_key:
            plan = fkr.build_plan([h for h in hosts if any(k[0] == h for k in sessions)],
                                  args.iterations)
            runner = fkr.Runner(driver, panel, args.iterations, warmup=args.warmup,
                                evidence=args.evidence, stop_on_failure=args.stop_on_failure,
                                panel_observation=args.panel_observation,
                                letters_enabled=letters_enabled)
            for group in plan['groups']:
                session = sessions.get((group['host'], group['target']))
                if session is None:
                    continue
                print(f'== {group["id"]} × {args.iterations} 次 ==', flush=True)
                runner.run_group(session, group)
            for (host, target), session in sessions.items():
                for confirm in fkr.CONFIRMATIONS:
                    runner.run_panel_check(session, confirm)
            matrix_report = {
                'plan': {k: v for k, v in plan.items() if k != 'groups'},
                'groups': runner.groups,
                'panelReports': runner.panel_reports,
                'checks': runner.checks,
                'failures': runner.failures,
            }
            checks.failures += runner.failures
            checks.results.extend(runner.checks)
        report = {
            'schema': 'gogaku.real-host-matrix.v2',
            'checkedAt': datetime.now(timezone.utc).isoformat(),
            'runId': run_id,
            'source': SOURCE,
            'excludedHosts': sorted(EXCLUDED_HOSTS),
            'inputSource': {'id': SOURCE,
                            'installedPath': str(fkr.INSTALLED_BINARY),
                            'installedSHA256': fkr.sha256_file(fkr.INSTALLED_BINARY)},
            'driver': {
                'probeSHA256': fkr.sha256_file(driver.temp / 'Gogaku IMK Probe.app/Contents/MacOS/Probe'),
                'axReaderSHA256': fkr.sha256_file(driver.ax_binary),
                'pageSHA256': fkr.sha256_file(ROOT / 'probes/real-host-test-page.html'),
            },
            'panelState': {'enabled': panel is not None,
                           'socket': args.panel_state_socket if panel is not None else None},
            'strictScenarios': [s['id'] for s in SCENARIOS],
            'inputLettersEnabled': letters_enabled,
            'hosts': sorted({f'{h}/{t}' for (h, t) in sessions}),
            'skipped': skipped,
            'firstKeyMatrix': matrix_report,
            'checks': checks.results,
            'failures': checks.failures,
        }
        args.report.parent.mkdir(parents=True, exist_ok=True)
        args.report.write_text(json.dumps(report, ensure_ascii=False, indent=2) + '\n')
        print(f'真实宿主严格回归：{len(checks.results)} 项检查，失败 {checks.failures} → {args.report}')
        return 1 if checks.failures else 0
    except fkr.GuardError as error:
        # 前台身份断言失败：立即停止，不向任何未确认目标投递按键。
        print(f'前台身份断言失败，整轮中止（未投递的按键不再补发）：{error}')
        return 5
    finally:
        # 只关闭本轮创建的文档／窗口（会话自己的 close）���
        for session in list(sessions.values()):
            try:
                session.close()
            except Exception:
                pass
        driver.close()


if __name__ == '__main__':
    raise SystemExit(main())
