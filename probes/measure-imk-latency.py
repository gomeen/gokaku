#!/usr/bin/env python3
"""真实 IMK 路径的逐键延迟测量驱动（不是离屏布局估算）。

路径：探针 AppKit 宿主（probes/imk-regression-host.swift）作为真实 IMK client，
按键经系统事件注入到已安装的 Gogaku 输入源，候选窗 enqueue／首次显示发生在
输入法进程的主 runloop。测量值全部来自验收构建的私有 socket（ValidationMonitor
的真实 InputController 回调样本），不是本地推算。

做法
----
1. 冻结四组确定性按键序列：short（短组合）、long（长组合）、paging（翻页）、
   punct（组合中标点）。序列表写进报告并附哈希，内容固定不随运行变化。
2. 按固定顺序循环这些序列，直到累计按键事件数达到目标（默认 10000）。
3. 每个键之间留固定间隔（默认 15ms，范围 10–20ms）：给输入法进程主 runloop
   执行候选 enqueue 与首次显示的机会；每个组合的首次显示都要被采到。
4. 计时前 socket reset，计时后 metrics 取真实样本；样本只含耗时与状态，
   不含任何文字。
5. 绑定证据：安装版输入源二进制与随包 dylib 的 SHA-256、探针二进制哈希、
   序列表哈希。
6. 记录环境：pmset -g therm、sysctl loadavg、显示器唤醒状态、caffeinate 断言、
   电源状态；计时前后各一次。

约束
----
* 正式计时不与构建并行：开始前检查是否有 swift/swiftc/xcodebuild/clang/cmake 等
  构建进程在跑，发现即中止（除非显式 --allow-parallel-build）。
* 严禁自动重试：任何一次投递失败或样本缺失都原样记录，不重发、不修改样本。
* 前台身份由探针的守卫负责：前台应用不是探针窗口时立即中止投递。
* 样本口径：计时前 socket reset，计时后一次 metrics 取全部样本，逐条落盘不裁剪。
  commitCallNs 只是 insertText 调用时长；选中候选到宿主收到文字的门槛使用探针宿主
  keyDown 与 insertText 完成时间戳配对，只有全部确认事件均成功配对时才可判定。
  宿主接收指标仅代表 AppKit 探针，不外推其他宿主。
* 正式门槛逐项判定并写入 acceptance；不达标返回 1。--check-report 可只检查既有
  报告，保留原始样本；不足一万事件的定位短测不能作为正式通过证据。

用法
----
    python3 probes/measure-imk-latency.py --events 10000 --interval-ms 15
报告：docs/validation/imk-latency.json
样本：docs/validation/imk-latency-samples.json
"""
import argparse
import ctypes
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import statistics
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / 'probes'))

import first_key_regression as fkr  # noqa: E402

SOURCE = fkr.SOURCE
INSTALLED_BUNDLE = Path.home() / 'Library/Input Methods/Gogaku.app'

# 冻结的确定性按键序列。键名对应 probes/imk-regression-host.swift 的 KEY_CODES。
# 每组都以确认动作收尾，保证下一组从无组合状态开始。
SEQUENCES = [
    {'id': 'short', 'label': '短组合：nihc＋空格',
     'keys': ['n', 'i', 'h', 'c', 'space']},
    {'id': 'long', 'label': '长句：我想每天花一点时间学习英语（冻结用例 long-learning）',
     'keys': list('woxlmwtmhxyidmuijmxtxiykyu') + ['space']},
    {'id': 'paging', 'label': '翻页：zhong 小鹤编码 vs＋四次 . ＋一次 , ＋空格',
     'keys': ['v', 's', '.', '.', '.', '.', ',', 'space']},
    {'id': 'punct', 'label': '组合中标点：nihc＋; 一次上屏',
     'keys': ['n', 'i', 'h', 'c', ';']},
]

BUILD_PROCESS_NAMES = ['swift', 'swiftc', 'xcodebuild', 'clang', 'cc', 'cmake', 'ninja', 'make']


def now_iso():
    return datetime.now(timezone.utc).isoformat()


def run_output(args, timeout=20):
    try:
        result = subprocess.run(args, capture_output=True, text=True, timeout=timeout)
    except (OSError, subprocess.TimeoutExpired) as error:
        return f'<{type(error).__name__}: {error}>'
    text = (result.stdout or '').strip()
    if not text:
        text = (result.stderr or '').strip()
    return text


def capture_environment():
    """计时前后的环境快照：热状态、负载、显示器唤醒、caffeinate、电源。"""
    power = run_output(['pmset', '-g'])
    graphics = ctypes.CDLL('/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics')
    graphics.CGMainDisplayID.restype = ctypes.c_uint32
    graphics.CGDisplayIsAsleep.argtypes = [ctypes.c_uint32]
    graphics.CGDisplayIsAsleep.restype = ctypes.c_bool
    display_awake = not graphics.CGDisplayIsAsleep(graphics.CGMainDisplayID())
    sleep_state = ''
    for line in power.splitlines():
        if line.strip().startswith('sleep'):
            sleep_state = line.strip()
    return {
        'at': now_iso(),
        'pmsetTherm': run_output(['pmset', '-g', 'therm']),
        'pmset': power,
        'loadavg': run_output(['sysctl', '-n', 'vm.loadavg']),
        'battery': run_output(['pmset', '-g', 'batt']),
        'displayAwake': display_awake,
        'sleepState': sleep_state,
        'caffeinateProcesses': run_output(['pgrep', '-lf', 'caffeinate']),
    }


def running_builds():
    found = []
    for name in BUILD_PROCESS_NAMES:
        output = run_output(['pgrep', '-x', name])
        if output and not output.startswith('<'):
            found.append({'name': name, 'pids': output.replace('\n', ' ')})
    return found


def bind_artifacts(bundle):
    """绑定安装版输入源的可执行文件与随包 dylib 哈希。"""
    entries = []
    if not bundle.exists():
        return entries
    for path in sorted(bundle.rglob('*')):
        if not path.is_file():
            continue
        relative = str(path.relative_to(bundle))
        is_binary = path.parent.name == 'MacOS'
        is_dylib = path.suffix == '.dylib'
        if not (is_binary or is_dylib):
            continue
        entries.append({'path': relative, 'size': path.stat().st_size,
                        'sha256': fkr.sha256_file(path)})
    return entries


# insertText 调用时间与真实宿主收到文字分别记录，不混用。
METRIC_SCOPE = {
    'hostReadNs': '写入前的宿主身份、选区和 marked range 读取（每回调累计）',
    'markedWriteNs': '同步写入宿主 marked text',
    'anchorReadNs': 'marked text 写入后的重锚读取',
    'callbackNs': 'IMK handle 回调总时长（主线程实测）',
    'coreNs': '共享核心同步处理时长',
    'renderNs': '按键到候选渲染完成（含排队）',
    'firstDisplayNs': '组合首键到候选首次显示',
    'commitCallNs': ('仅 insertText 调用时长；不含核心选词与宿主实际接收，'
                     '不能作为「选中候选到宿主收到文字」门槛的证据'),
}

def evaluate_report(report):
    """仅判定这次真实路径测量的门槛，不代表完整交付验收。"""
    summary = report.get('summary') or {}
    loop = report.get('loop') or {}
    compositions = loop.get('compositions', 0)
    coverage = report.get('coverage') or {}
    receipt = report.get('limitations', {}).get('selectionToHostLatency', {})
    checks = {
        'atLeast10000Events': loop.get('actualEvents', 0) >= 10000,
        'allCallbacksCaptured': summary.get('count') == loop.get('actualEvents'),
        'allFirstDisplaysCaptured': compositions > 0 and coverage.get('measuredFirstDisplays') == compositions,
        'validClocks': summary.get('invalidClockSamples') == 0,
        'frontGuard': report.get('guardFailures') == [],
        'hiddenInConfirmationCallback': compositions > 0 and summary.get('confirmationSamples') == compositions
            and summary.get('confirmationHiddenFalse') == 0 and summary.get('visibleAtReturnTrue') == 0,
        'hostReceiptsPaired': receipt.get('verifiable') is True,
    }
    for metric, percentile, limit in [
        ('callbackNs', 'p95', 5_000_000), ('callbackNs', 'p99', 10_000_000),
        ('renderNs', 'p95', 30_000_000), ('renderNs', 'p99', 50_000_000),
        ('firstDisplayNs', 'p95', 30_000_000), ('firstDisplayNs', 'p99', 50_000_000),
    ]:
        value = summary.get(metric, {}).get(percentile)
        checks[f'{metric}.{percentile}'] = isinstance(value, (int, float)) and value <= limit
    value = receipt.get('p95Ns')
    checks['selectionToHost.p95'] = isinstance(value, (int, float)) and value <= 30_000_000
    return {'passed': all(checks.values()), 'checks': checks,
            'scope': '热态 AppKit 探针；不包含其他宿主、冷启动、内存或两小时稳定性验收'}


def summarize(samples):
    """保留所有离群值；汇总真实路径样本，不作环境折扣。"""
    summary = {'count': len(samples), 'metricScope': METRIC_SCOPE}
    for field in ('callbackNs', 'coreNs', 'hostReadNs', 'markedWriteNs', 'anchorReadNs', 'commitCallNs', 'renderNs', 'firstDisplayNs'):
        values = sorted(s[field] for s in samples if isinstance(s.get(field), (int, float)))
        if not values:
            continue
        summary[field] = {
            'count': len(values),
            'p50': int(statistics.median(values)),
            'p95': values[min(len(values) - 1, int(len(values) * 0.95))],
            'p99': values[min(len(values) - 1, int(len(values) * 0.99))],
            'max': values[-1],
        }
    first_display = [s for s in samples if s.get('firstDisplay')]
    summary['firstDisplaySamples'] = len(first_display)
    summary['confirmationSamples'] = sum(1 for s in samples if 'confirmationHidden' in s)
    summary['confirmationHiddenFalse'] = sum(
        1 for s in samples if 'confirmationHidden' in s and not s.get('confirmationHidden'))
    summary['visibleAtReturnTrue'] = sum(
        1 for s in samples if 'confirmationHidden' in s and s.get('visibleAtReturn') is True)
    summary['invalidClockSamples'] = sum(1 for sample in samples if sample.get('clockValid') is not True)
    return summary


def main():
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--events', type=int, default=10000, help='目标按键事件数（默认 10000）')
    parser.add_argument('--interval-ms', type=float, default=15.0,
                        help='键间隔毫秒（10–20，给主 runloop 执行 enqueue 的时间）')
    parser.add_argument('--panel-state-socket', default=str(fkr.DEFAULT_SOCKET),
                        help='验收状态 socket 路径')
    parser.add_argument('--no-panel-state', action='store_true',
                        help='不读取 socket 样本（只记录事件投递，不计时）')
    parser.add_argument('--allow-parallel-build', action='store_true',
                        help='允许与构建并行（默认禁止）')
    parser.add_argument('--no-caffeinate', action='store_true',
                        help='不申请 caffeinate 断言（默认申请，保持显示器唤醒）')
    parser.add_argument('--report', type=Path, default=ROOT / 'docs/validation/imk-latency.json')
    parser.add_argument('--samples', type=Path, default=ROOT / 'docs/validation/imk-latency-samples.json')
    parser.add_argument('--evidence', type=Path, default=ROOT / 'docs/validation/imk-latency-cycles.jsonl')
    parser.add_argument('--check-report', type=Path, help='只判定既有报告，不操作输入源或前台')
    args = parser.parse_args()
    if args.check_report:
        report = json.loads(args.check_report.read_text())
        sample_path = Path(report['samplesFile'])
        report['summary'] = summarize(json.loads(sample_path.read_text()))
        verdict = evaluate_report(report)
        print(json.dumps(verdict, ensure_ascii=False, indent=2))
        return 0 if verdict['passed'] else 1

    if not (10.0 <= args.interval_ms <= 20.0):
        parser.error('--interval-ms 必须在 10–20 之间（要保证主 runloop 有机会执行 enqueue）')

    builds = running_builds()
    if builds and not args.allow_parallel_build:
        print('检测到构建进程在运行，正式计时不与构建并行：', json.dumps(builds, ensure_ascii=False))
        return 3

    panel = None if args.no_panel_state else fkr.PanelStateClient(args.panel_state_socket)
    if panel is not None and not panel.available():
        print(f'验收状态 socket 不存在：{panel.path}'
              f'（需要 scripts/build.py --validation 构建、{fkr.VALIDATION_MARKER} 私有开关'
              f'并重启输入法进程）')
        return 2

    driver = fkr.Driver()
    caffeinate = None
    cycles = []
    samples = []
    guard_failures = []
    try:
        ready = driver.build()
        probe_pid = ready.get('pid')
        run_id = f'{int(time.time())}{os.getpid() % 10000:04d}'
        marker = f'GOGAKU-PROBE-{run_id}-latency'
        state = driver.ask(op='setMarker', marker=marker)
        guard = {'bundle': fkr.PROBE_BUNDLE_ID, 'pid': state.get('frontPid') or probe_pid,
                 'marker': marker}
        driver.ask(op='focus', field=1)
        # 输入源切换只在探针自身窗口做一次。
        selected = driver.ask(op='select', id=SOURCE)
        if selected.get('source') != SOURCE:
            print(f'输入源切换失败：当前 {selected.get("source")!r}')
            return 2
        time.sleep(1.0)  # 热态测量：等待新控制器的异步词库初始化，不计入样本。
        driver.ask(op='reset')
        warmup = []
        for index in range(2):
            reply = driver.ask(op='pace', codes=SEQUENCES[0]['keys'],
                               intervalMs=args.interval_ms, guard=guard)
            if not reply.get('guardOk'):
                print('预热前台守卫失败')
                return 4
            host = driver.ask(op='state')
            warmup.append({'iteration': index, 'text': host.get('rawText', '')})
            if host.get('rawText') != '你好' * (index + 1):
                print('预热正文不符：', json.dumps(warmup, ensure_ascii=False))
                return 5
        driver.ask(op='reset')
        if not args.no_caffeinate:
            caffeinate = subprocess.Popen(['caffeinate', '-d', '-i', '-w', str(probe_pid)],
                                          stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        if panel is not None:
            panel.reset()
        driver.ask(op='resetReceipts')
        environment_before = capture_environment()
        print(f'开始计时：目标 {args.events} 个按键事件，键间隔 {args.interval_ms:g}ms')
        events = 0
        cycle_index = 0
        started = time.time()
        while events < args.events:
            for sequence in SEQUENCES:
                reply = driver.ask(op='pace', codes=sequence['keys'],
                                   intervalMs=args.interval_ms, guard=guard, delay=0.05)
                if not reply.get('guardOk'):
                    guard_failures.append({'cycle': cycle_index, 'sequence': sequence['id'],
                                           'reason': reply.get('guardReason'),
                                           'front': reply.get('guardFront')})
                    print(f'前台守卫中止投递：{reply.get("guardReason")} '
                          f'（前台 {reply.get("guardFront")}）')
                    return 4
                events += len(sequence['keys'])
                host = driver.ask(op='state')
                cycles.append({
                    'cycle': cycle_index,
                    'sequence': sequence['id'],
                    'events': len(sequence['keys']),
                    'cumulativeEvents': events,
                    'hostTextLength': len(host.get('rawText', '')),
                    'inserts': host.get('inserts'),
                    'at': now_iso(),
                })
            cycle_index += 1
        elapsed = time.time() - started
        environment_after = capture_environment()
        if panel is not None:
            metrics = panel.metrics()
            samples = metrics.get('samples', [])
        expected_compositions = cycle_index * len(SEQUENCES)
        receipts = driver.ask(op='receipts').get('insertionReceipts', [])
        paired = [r['latencyNs'] for r in receipts if 'latencyNs' in r]
        paired.sort()
        selection_receipt = {
            'verifiable': len(paired) == expected_compositions == len(receipts),
            'status': 'measured' if len(paired) == expected_compositions == len(receipts) else 'unverified',
            'metric': '确认键事件时间戳 → 探针宿主 insertText 完成',
            'expected': expected_compositions, 'received': len(receipts), 'paired': len(paired),
            'scope': '真实 IMK 路径的 AppKit 探针宿主；不外推其他宿主',
            'reason': '仅当所有确认均与宿主 keyDown 时间戳配对时可判定',
        }
        if paired:
            selection_receipt['p95Ns'] = paired[min(len(paired) - 1, int(len(paired) * 0.95))]
            selection_receipt['maxNs'] = paired[-1]
        report = {
            'schema': 'gogaku.imk-latency.v1',
            'checkedAt': now_iso(),
            'runId': run_id,
            'inputSource': {
                'id': SOURCE,
                'bundle': str(INSTALLED_BUNDLE),
                'artifacts': bind_artifacts(INSTALLED_BUNDLE),
            },
            'driver': {
                'probeSHA256': fkr.sha256_file(driver.temp / 'Gogaku IMK Probe.app/Contents/MacOS/Probe'),
                'sequencesSHA256': fkr.sha256_text(json.dumps(SEQUENCES, ensure_ascii=False,
                                                             sort_keys=True)),
                'socket': args.panel_state_socket if panel is not None else None,
            },
            'sequences': SEQUENCES,
            'loop': {
                'targetEvents': args.events,
                'actualEvents': events,
                'cycles': cycle_index,
                'compositions': expected_compositions,
                'intervalMs': args.interval_ms,
                'elapsedSeconds': round(elapsed, 3),
                'eventsPerSecond': round(events / elapsed, 1) if elapsed else None,
                'warmupCompositions': len(warmup),
            },
            'environment': {'before': environment_before, 'after': environment_after,
                            'parallelBuildsAtStart': builds},
            'limitations': {'selectionToHostLatency': selection_receipt},
            'hostInsertionReceipts': receipts,
            'guardFailures': guard_failures,
            'summary': summarize(samples) if samples else None,
            'samplesFile': str(args.samples),
            'cyclesFile': str(args.evidence),
            'sampleCount': len(samples),
            'coverage': {
                'callbacksComplete': len(samples) >= events,
                'expectedFirstDisplays': expected_compositions,
                'measuredFirstDisplays': sum(1 for sample in samples if sample.get('firstDisplay')),
            },
        }
        report['acceptance'] = evaluate_report(report)
        args.samples.parent.mkdir(parents=True, exist_ok=True)
        args.samples.write_text(json.dumps(samples, ensure_ascii=False, indent=1) + '\n')
        args.evidence.parent.mkdir(parents=True, exist_ok=True)
        with args.evidence.open('w') as handle:
            for cycle in cycles:
                handle.write(json.dumps(cycle, ensure_ascii=False) + '\n')
        args.report.parent.mkdir(parents=True, exist_ok=True)
        args.report.write_text(json.dumps(report, ensure_ascii=False, indent=2) + '\n')
        print(f'IMK 延迟测量：{events} 个事件，{cycle_index} 轮，'
              f'样本 {len(samples)} 条，用时 {elapsed:.1f}s → {args.report}')
        print(json.dumps(report['acceptance'], ensure_ascii=False))
        return 0 if report['acceptance']['passed'] else 1
    finally:
        if caffeinate is not None:
            try:
                caffeinate.terminate()
            except Exception:
                pass
        driver.close()


if __name__ == '__main__':
    raise SystemExit(main())
