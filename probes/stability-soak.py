#!/usr/bin/env python3
"""稳定性浸泡驱动：多轮真实宿主回归持续运行，产出时长与输入法进程内存趋势。

与一次性宿主矩阵的差别：
1. 按 --minutes 持续调度 validate-real-hosts.py 短轮次（默认每轮 25 组首键矩阵），
   每轮产出独立报告（用例结果与完成数量可核对），不合并掩盖失败。
2. 每轮前后采样 GogakuInput 进程 RSS（ps，无第三方依赖），逐轮记录内存趋势。
3. 汇总报告含总时长、总检查数、总失败数、最大／均值 RSS 与逐轮明细；
   任一轮失败或轮次报告缺失都使退出码非零，不得作为稳定性通过证据。
4. 前台身份守卫由被调用的 validate-real-hosts.py 自带（GuardError 即中止）。

用法：
    python3 probes/stability-soak.py --minutes 120 \
        --hosts textedit,orca-pty --iterations 25 \
        --report docs/validation/verify/stability-soak.json
"""
import argparse
import json
import statistics
import subprocess
import sys
import time
from datetime import datetime, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
INSTALLED_BINARY = Path.home() / 'Library/Input Methods/Gogaku.app/Contents/MacOS/GogakuInput'


def now_iso():
    return datetime.now(timezone.utc).isoformat()


def rss_kb(pid):
    try:
        out = subprocess.run(['ps', '-o', 'rss=', '-p', str(pid)],
                             capture_output=True, text=True, timeout=10)
        return int(out.stdout.strip().splitlines()[0])
    except (ValueError, IndexError, subprocess.SubprocessError):
        return None


def input_method_pid():
    out = subprocess.run(['pgrep', '-x', 'GogakuInput'],
                         capture_output=True, text=True, timeout=10)
    pids = [int(line) for line in out.stdout.split() if line.strip().isdigit()]
    return pids[0] if pids else None


def main():
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--minutes', type=float, default=120.0, help='目标浸泡时长（分钟，默认 120）')
    parser.add_argument('--hosts', default='textedit,orca-pty', help='每轮宿主列表')
    parser.add_argument('--iterations', type=int, default=25, help='每轮首键矩阵组内轮次')
    parser.add_argument('--rounds-dir', type=Path, default=None, help='逐轮报告目录')
    parser.add_argument('--report', type=Path, default=ROOT / 'docs/validation/verify/stability-soak.json')
    args = parser.parse_args()

    rounds_dir = args.rounds_dir or args.report.parent / 'stability-rounds'
    rounds_dir.mkdir(parents=True, exist_ok=True)
    args.report.parent.mkdir(parents=True, exist_ok=True)

    deadline = time.monotonic() + args.minutes * 60
    rounds = []
    memory_trend = []
    started = now_iso()
    start_monotonic = time.monotonic()
    index = 0
    aborted = None

    try:
        while time.monotonic() < deadline:
            index += 1
            round_report = rounds_dir / f'round-{index:03d}.json'
            pid_before = input_method_pid()
            rss_before = rss_kb(pid_before) if pid_before else None
            if rss_before is not None:
                memory_trend.append({'at': now_iso(), 'phase': f'round-{index}-before', 'rssKB': rss_before})
            started_monotonic = time.monotonic()
            result = subprocess.run(
                [sys.executable, str(ROOT / 'probes/validate-real-hosts.py'),
                 '--hosts', args.hosts, '--iterations', str(args.iterations),
                 '--report', str(round_report)],
                cwd=ROOT, capture_output=True, text=True, timeout=3600)
            (rounds_dir / f'round-{index:03d}.log').write_text(result.stdout + result.stderr)
            checks = failures = None
            installed_sha = None
            try:
                data = json.loads(round_report.read_text())
                checks = len(data.get('checks', []))
                failures = data.get('failures')
                installed_sha = data.get('inputSource', {}).get('installedSHA256')
            except (OSError, json.JSONDecodeError):
                pass
            pid_after = input_method_pid()
            rss_after = rss_kb(pid_after) if pid_after else None
            if rss_after is not None:
                memory_trend.append({'at': now_iso(), 'phase': f'round-{index}-after', 'rssKB': rss_after})
            rounds.append({
                'index': index,
                'exitCode': result.returncode,
                'durationSeconds': round(time.monotonic() - started_monotonic, 1),
                'checks': checks,
                'failures': failures,
                'installedSHA256': installed_sha,
                'rssBeforeKB': rss_before,
                'rssAfterKB': rss_after,
                'reportPath': str(round_report),
            })
            print(f'轮次 {index}：exit={result.returncode} checks={checks} failures={failures} '
                  f'rss={rss_before}→{rss_after}KB（{len(rounds)} 轮，累计 '
                  f'{(time.monotonic() - start_monotonic) / 60:.1f} 分钟）', flush=True)
            # 守卫失败（exit 5）或输入源切换失败（exit 2）：立即停止，不再继续注入。
            if result.returncode in (2, 5):
                aborted = {'round': index, 'exitCode': result.returncode,
                           'reason': 'identity/guard abort' if result.returncode == 5 else 'input source unavailable'}
                break
    except KeyboardInterrupt:
        aborted = {'reason': 'interrupted'}
    finally:
        finished = now_iso()
        duration = time.monotonic() - start_monotonic
        samples = [item['rssKB'] for item in memory_trend if item.get('rssKB') is not None]
        total_checks = sum(r['checks'] or 0 for r in rounds)
        total_failures = sum(r['failures'] or 0 for r in rounds)
        bad_rounds = [r['index'] for r in rounds
                      if r['exitCode'] != 0 or r['failures'] != 0
                      or r['checks'] is None or r['installedSHA256'] is None]
        report = {
            'schema': 'gogaku.stability-soak.v1',
            'startedAt': started,
            'finishedAt': finished,
            'durationSeconds': round(duration, 1),
            'targetMinutes': args.minutes,
            'hosts': args.hosts,
            'iterationsPerRound': args.iterations,
            'roundsCompleted': len(rounds),
            'totalChecks': total_checks,
            'totalFailures': total_failures,
            'badRounds': bad_rounds,
            'aborted': aborted,
            'memoryTrend': memory_trend,
            'memorySummaryKB': {
                'samples': len(samples),
                'maxRSSKB': max(samples) if samples else None,
                'meanRSSKB': round(statistics.mean(samples)) if samples else None,
                'firstRSSKB': samples[0] if samples else None,
                'lastRSSKB': samples[-1] if samples else None,
            },
            'rounds': rounds,
            'installedBinary': str(INSTALLED_BINARY),
            'installedSHA256': subprocess.run(
                ['shasum', '-a', '256', str(INSTALLED_BINARY)],
                capture_output=True, text=True).stdout.split()[0:1],
        }
        args.report.write_text(json.dumps(report, ensure_ascii=False, indent=2) + '\n')
        complete = (duration >= args.minutes * 60 * 0.98 and not bad_rounds
                    and not aborted and len(samples) >= 2)
        print(f'稳定性浸泡：{len(rounds)} 轮 / {duration / 60:.1f} 分钟，检查 {total_checks}，'
              f'失败 {total_failures}，内存峰值 {report["memorySummaryKB"]["maxRSSKB"]}KB'
              f'（{"完成" if complete else "未完成"}）→ {args.report}')
        return 0 if complete else 1


if __name__ == '__main__':
    raise SystemExit(main())
