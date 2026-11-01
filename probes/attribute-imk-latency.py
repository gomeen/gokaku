#!/usr/bin/env python3
"""主线程耗时归因探针：有限对照定位 5ms/10ms 未达标的原因。

不重新评测引擎，不改正式门槛；已有 10,035 事件正式报告仍是失败基线。
沿用与正式测量相同的 Release 安装件、冻结按键序列、15ms 键间隔、默认设置；
每个对照场景 540 个事件（12 轮 × 45 键），文档准备与复位都在计时区间之外。

对照维度（一次只改一个因素）：
  body-length    探针正文 0／1000／4500 字（每组完成后恢复同一初始文档，
                 区分「正文长度」与「累计运行时间」——短文档会在长文档之后复测）
  structure      4500 字单段 vs 分段（换行）
  host-flags     探针文本栈：撤销记录、自动拼写纠正（只改探针，不改用户应用）
  display-path   展开全拼（默认）vs 原码 vs 关闭输入区字母（仅归因用）

分项口径（同一事件内，不跨事件相加）：
  IME 侧  hostReadNs（写入前宿主事实读取）markedWriteNs（同步 marked text 写入）
          anchorReadNs（写入后重锚读取）coreNs（引擎队列同步总时长）
          queueWaitNs（进队列前等待）coreExecNs（引擎实际执行）commitCallNs
  宿主侧  markedDurationsNs（探针 setMarkedText 实际耗时，按事件顺序与 IME 侧配对）
          insertionReceipts.durationNs（探针 insertText 实际耗时）

用法：
    python3 probes/attribute-imk-latency.py --out docs/validation/final-mac/attribution
"""
import argparse
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

import first_key_regression as fkr          # noqa: E402
import importlib.util                       # noqa: E402

_spec = importlib.util.spec_from_file_location(
    'measure_imk_latency', ROOT / 'probes/measure-imk-latency.py')
mil = importlib.util.module_from_spec(_spec)
sys.modules['measure_imk_latency'] = mil
_spec.loader.exec_module(mil)

SOURCE = fkr.SOURCE
SEQUENCES = mil.SEQUENCES
EVENTS_PER_SCENARIO = 540

# 对照场景表：name → 准备动作（都在计时区间外执行）。
# text：(正文, 选区位置)；flags：探针文本栈开关；settings：输入法设置（测试后恢复）。
def _repeated(total):
    base = '现在可以然后怎样可以现在然后'
    return (base * (total // len(base) + 1))[:total]


BASE_TEXT_SINGLE_1000 = _repeated(1000)
BASE_TEXT_SINGLE_4500 = _repeated(4500)
BASE_TEXT_SEGMENTED_4500 = '\n'.join([_repeated(90)] * 50)   # 50 段 × 90 字＝4500 字＋换行

SCENARIOS = [
    {'name': 'L0-base', 'text': '', 'flags': {}, 'settings': {}},
    {'name': 'L1000', 'text': BASE_TEXT_SINGLE_1000, 'flags': {}, 'settings': {}},
    {'name': 'L4500', 'text': BASE_TEXT_SINGLE_4500, 'flags': {}, 'settings': {}},
    {'name': 'L0-repeat', 'text': '', 'flags': {}, 'settings': {}},
    {'name': 'L4500-segmented', 'text': BASE_TEXT_SEGMENTED_4500, 'flags': {}, 'settings': {}},
    {'name': 'L4500-undo-on', 'text': BASE_TEXT_SINGLE_4500,
     'flags': {'allowsUndo': True}, 'settings': {}},
    {'name': 'L4500-spellcheck-on', 'text': BASE_TEXT_SINGLE_4500,
     'flags': {'continuousSpellChecking': True, 'automaticSpellingCorrection': True,
               'automaticTextReplacement': True, 'automaticTextCompletion': True},
     'settings': {}},
    {'name': 'L4500-raw-preedit', 'text': BASE_TEXT_SINGLE_4500,
     'flags': {}, 'settings': {'fullPinyinPreedit': False}},
    {'name': 'L4500-letters-off', 'text': BASE_TEXT_SINGLE_4500,
     'flags': {}, 'settings': {'inputLettersEnabled': False}},
    {'name': 'L0-letters-off-repeat', 'text': '', 'flags': {},
     'settings': {'inputLettersEnabled': False}},
]


def now_iso():
    return datetime.now(timezone.utc).isoformat()


def percentiles(values):
    if not values:
        return None
    values = sorted(values)
    return {'count': len(values),
            'p50': int(statistics.median(values)),
            'p95': values[min(len(values) - 1, int(len(values) * 0.95))],
            'p99': values[min(len(values) - 1, int(len(values) * 0.99))],
            'max': values[-1]}


def summarize_samples(samples):
    """按事件拆分项汇总；全部样本保留离群值。"""
    summary = {'count': len(samples)}
    for field in ('callbackNs', 'coreNs', 'queueWaitNs', 'coreExecNs', 'hostReadNs',
                  'markedWriteNs', 'anchorReadNs', 'commitCallNs', 'renderNs',
                  'firstDisplayNs'):
        values = [s[field] for s in samples if isinstance(s.get(field), (int, float))]
        if values:
            summary[field] = percentiles(values)
    # 插字事件与首次显示单列
    commits = [s for s in samples if 'commitCallNs' in s]
    summary['commitEvents'] = len(commits)
    summary['commitHiddenFalse'] = sum(1 for s in commits if s.get('confirmationHidden') is not True)
    summary['firstDisplayEvents'] = sum(1 for s in samples if s.get('firstDisplay'))
    return summary


def run_scenario(driver, panel, guard, scenario, caffeinate_hold):
    """执行一个对照场景：准备（计时外）→ 标记场景 → 540 事件 → 收样本。"""
    name = scenario['name']
    # -- 准备（计时区间之外）----------------------------------------------
    original_settings = {}
    if scenario['settings']:
        original_settings = fkr.write_settings(scenario['settings'], driver.notify_binary)
    if scenario['flags']:
        driver.ask(op='flags', **scenario['flags'])
    # 准备顺序：先 reset（清空正文与回执）再 set（写入对照正文）；
    # reset 会清空正文，不能放在 set 之后。
    driver.ask(op='reset')
    if 'text' in scenario:
        driver.ask(op='set', text=scenario['text'], selection=[len(scenario['text']), 0])
        driver.ask(op='resetReceipts')
        driver.ask(op='resetMarkedReceipts')
    else:
        driver.ask(op='resetReceipts')
        driver.ask(op='resetMarkedReceipts')
    panel.reset()
    panel.scenario(name)
    # -- 计时区间 ----------------------------------------------------------\
    events = 0
    cycle_index = 0
    started = time.time()
    while events < EVENTS_PER_SCENARIO:
        for sequence in SEQUENCES:
            reply = driver.ask(op='pace', codes=sequence['keys'],
                               intervalMs=15.0, guard=guard, delay=0.05)
            if not reply.get('guardOk'):
                raise RuntimeError(f'{name}: 前台守卫中止投递 {reply.get("guardReason")}')
            events += len(sequence['keys'])
        cycle_index += 1
    elapsed = time.time() - started
    # -- 收尾（计时区间之外）----------------------------------------------
    metrics = panel.metrics()
    samples = metrics.get('samples', [])
    marked = driver.ask(op='markedReceipts')
    receipts = driver.ask(op='receipts').get('insertionReceipts', [])
    host = driver.ask(op='state')
    # IME 侧 markedWriteNs 与宿主侧 setMarkedText 按事件顺序配对
    ime_marked = [s['markedWriteNs'] for s in samples
                  if isinstance(s.get('markedWriteNs'), (int, float))]
    host_marked = marked.get('markedDurationsNs') or []
    paired = list(zip(ime_marked, host_marked))
    result = {
        'scenario': name,
        'at': now_iso(),
        'elapsedSeconds': round(elapsed, 3),
        'actualEvents': events,
        'cycles': cycle_index,
        'compositions': cycle_index * len(SEQUENCES),
        'hostTextLengthAfter': len(host.get('rawText', '')),
        'hostFlags': host.get('hostFlags'),
        'settingsApplied': scenario['settings'],
        'summary': summarize_samples(samples),
        'hostMarkedWrites': {
            'count': len(host_marked),
            'durationNs': percentiles(host_marked),
        },
        'hostInsertions': {
            'count': len(receipts),
            'durationNs': percentiles([r['durationNs'] for r in receipts
                                       if 'durationNs' in r]),
            'latencyNs': percentiles([r['latencyNs'] for r in receipts
                                      if 'latencyNs' in r]),
        },
        'markedWritePairing': {
            'paired': len(paired),
            'imeP95': percentiles([a for a, _ in paired]),
            'hostP95': percentiles([b for _, b in paired]),
        },
        'samplesFile': None,   # 由调用方填充
        'environment': mil.capture_environment(),
    }
    # -- 恢复（计时区间之外）----------------------------------------------
    if scenario['flags']:
        driver.ask(op='flags', **{key: False for key in scenario['flags']})
    if original_settings:
        restore = {key: value for key, value in original_settings.items()
                   if value is not None}
        if 'fullPinyinPreedit' not in restore and 'fullPinyinPreedit' in scenario['settings']:
            restore['fullPinyinPreedit'] = True
        if 'inputLettersEnabled' not in restore and 'inputLettersEnabled' in scenario['settings']:
            restore['inputLettersEnabled'] = True
        if restore:
            fkr.write_settings(restore, driver.notify_binary)
    panel.scenario('idle')
    return result, samples


def main():
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--out', type=Path,
                        default=ROOT / 'docs/validation/final-mac/attribution')
    parser.add_argument('--panel-state-socket', default=str(fkr.DEFAULT_SOCKET))
    parser.add_argument('--only', default='', help='逗号分隔：只跑这些场景')
    parser.add_argument('--no-caffeinate', action='store_true')
    args = parser.parse_args()

    scenarios = SCENARIOS
    if args.only:
        wanted = {s.strip() for s in args.only.split(',') if s.strip()}
        scenarios = [s for s in SCENARIOS if s['name'] in wanted]
        missing = wanted - {s['name'] for s in scenarios}
        if missing:
            parser.error(f'未知场景：{missing}')

    builds = mil.running_builds()
    if builds:
        print('检测到构建进程，归因测量不与构建并行：', json.dumps(builds, ensure_ascii=False))
        return 3
    panel = fkr.PanelStateClient(args.panel_state_socket)

    args.out.mkdir(parents=True, exist_ok=True)
    driver = fkr.Driver()
    caffeinate = None
    results = []
    try:
        ready = driver.build()
        probe_pid = ready.get('pid')
        run_id = f'{int(time.time())}{os.getpid() % 10000:04d}'
        marker = f'GOGAKU-PROBE-{run_id}-attr'
        state = driver.ask(op='setMarker', marker=marker)
        guard = {'bundle': fkr.PROBE_BUNDLE_ID, 'pid': state.get('frontPid') or probe_pid,
                 'marker': marker}
        driver.ask(op='focus', field=1)
        selected = driver.ask(op='select', id=SOURCE)
        if selected.get('source') != SOURCE:
            print(f'输入源切换失败：当前 {selected.get("source")!r}')
            return 2
        # socket 在输入法进程被探针激活后才出现：真实问答确认可用。
        deadline = time.time() + 20
        while time.time() < deadline and not panel.available():
            time.sleep(0.3)
        if not panel.available():
            print(f'验收状态 socket 不可用：{panel.path}（需要验收构建＋私有开关＋重启输入法）')
            return 2
        time.sleep(1.0)
        if not args.no_caffeinate:
            caffeinate = subprocess.Popen(['caffeinate', '-d', '-i', '-w', str(probe_pid)],
                                          stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        for scenario in scenarios:
            print(f'== 归因场景 {scenario["name"]} '
                  f'(text={len(scenario.get("text", ""))} 字) ==', flush=True)
            result, samples = run_scenario(driver, panel, guard, scenario, caffeinate)
            sample_path = args.out / f'{scenario["name"]}-samples.json'
            sample_path.write_text(json.dumps(samples, ensure_ascii=False, indent=1) + '\n')
            result['samplesFile'] = str(sample_path)
            (args.out / f'{scenario["name"]}.json').write_text(
                json.dumps(result, ensure_ascii=False, indent=2) + '\n')
            results.append(result)
            summary = result['summary']
            callback = summary.get('callbackNs') or {}
            marked = summary.get('markedWriteNs') or {}
            host_marked = (result['hostMarkedWrites'].get('durationNs') or {})
            print(f'   {summary["count"]} 事件；callback p95 {callback.get("p95", 0)/1e6:.2f}ms '
                  f'p99 {callback.get("p99", 0)/1e6:.2f}ms；'
                  f'markedWrite p95 {marked.get("p95", 0)/1e6:.2f}ms；'
                  f'宿主 setMarkedText p95 {host_marked.get("p95", 0)/1e6:.2f}ms')
        report = {
            'schema': 'gogaku.imk-attribution.v1',
            'checkedAt': now_iso(),
            'runId': run_id,
            'inputSource': {'id': SOURCE,
                            'bundle': str(mil.INSTALLED_BUNDLE),
                            'artifacts': mil.bind_artifacts(mil.INSTALLED_BUNDLE)},
            'driver': {'probeSHA256': fkr.sha256_file(
                driver.temp / 'Gogaku IMK Probe.app/Contents/MacOS/Probe')},
            'sequences': SEQUENCES,
            'eventsPerScenario': EVENTS_PER_SCENARIO,
            'intervalMs': 15.0,
            'scenarios': results,
            'note': '归因对照不替代 10,035 事件正式报告；正式门槛仍以最终连续测量为准。',
        }
        (args.out / 'attribution.json').write_text(
            json.dumps(report, ensure_ascii=False, indent=2) + '\n')
        print(f'归因完成：{len(results)} 个场景 → {args.out / "attribution.json"}')
        return 0
    finally:
        if caffeinate is not None:
            try:
                caffeinate.terminate()
            except Exception:
                pass
        driver.close()


if __name__ == '__main__':
    raise SystemExit(main())
