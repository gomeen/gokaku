#!/usr/bin/env python3
"""翻译策略评测驱动：固定路线（资源/模板 → small100 候选 → quickmt 反向评分 → 加固检查）。

与 benchmark-translation-backends.py 的分工：
  - 后者测单模型后端（旧基线），本脚本测「组合策略」；
  - 本脚本复用其 Worker（stdio JSON 协议）与数据集，不重跑旧基线；
  - 输出可与语义审阅文件配对的请求级证据，供 scripts/summarize-translation-strategy.py 汇总。

用法：
  python3 probes/benchmark-translation-strategy.py --cases risk,holdout,short,confirm \
      --rounds 1 --output-dir probes/results/translation-strategy-dev
  python3 probes/benchmark-translation-strategy.py --cases final --rounds 5 \
      --lambda-file probes/results/translation-strategy-freeze.json \
      --output-dir probes/results/translation-strategy-final
"""
import argparse
import datetime
import hashlib
import importlib.util
import json
import os
import random
import shutil
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
PROBES = ROOT / 'probes'
sys.path.insert(0, str(PROBES))

import translation_strategy as strategy  # noqa: E402

FINAL_PATH = ROOT / 'validation/translation-final-set.json'
DEV_SUITES = ('risk', 'holdout', 'short', 'confirm')
SUITES = ('risk', 'holdout', 'short', 'confirm', 'speed', 'final')
EXPECTED = {
    'risk': {'total': 32},
    'holdout': {'total': 200},
    'short': {'total': 88},
    'confirm': {'total': 100},
    'speed': {'total': 8},
    'final': {'total': None},   # 由冻结文件声明，加载后校验
}


def load_benchmark_module():
    spec = importlib.util.spec_from_file_location(
        'benchmark_translation_backends', PROBES / 'benchmark-translation-backends.py')
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def sha256_file(path):
    digest = hashlib.sha256()
    with Path(path).open('rb') as handle:
        for chunk in iter(lambda: handle.read(1 << 20), b''):
            digest.update(chunk)
    return digest.hexdigest()


def now_utc():
    return datetime.datetime.now(datetime.timezone.utc).isoformat()


def load_cases(spec, benchmark):
    names = [name.strip() for name in spec.split(',') if name.strip()]
    unknown = [name for name in names if name not in SUITES]
    if unknown:
        raise SystemExit('unknown suites: %s' % unknown)
    by_suite = {}
    for name in names:
        if name == 'final':
            data = json.loads(FINAL_PATH.read_text())
            if data.get('status', '').startswith('draft'):
                raise SystemExit('final set is still a draft; freeze it first')
            cases = data['cases']
            expected = data.get('counts', {})
            for direction, count in expected.items():
                actual = sum(1 for case in cases if case['direction'] == direction)
                if actual != count:
                    raise SystemExit('final set %s: %d cases, expected %d'
                                     % (direction, actual, count))
        else:
            cases, loaded = benchmark.load_cases(name)
            cases = loaded[name]
        normalised = []
        for case in cases:
            case = dict(case)
            case['direction'] = strategy.normalize_direction(case.get('direction'))
            case['suite'] = name
            case.setdefault('expectedAction', benchmark.expected_action(case))
            case['timingBucket'] = benchmark.timing_bucket(case)
            normalised.append(case)
        by_suite[name] = normalised
    ids = {}
    for name, cases in by_suite.items():
        for case in cases:
            if case['id'] in ids:
                raise SystemExit('duplicate case id %s in %s and %s'
                                 % (case['id'], ids[case['id']], name))
            ids[case['id']] = name
    return by_suite


def case_hashes(by_suite):
    hashes = {}
    for name, cases in by_suite.items():
        payload = json.dumps(cases, ensure_ascii=False, sort_keys=True).encode('utf-8')
        hashes[name] = {'sha256': hashlib.sha256(payload).hexdigest(), 'count': len(cases)}
    return hashes


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--cases', default='risk,holdout,short,confirm')
    parser.add_argument('--rounds', type=int, default=1)
    parser.add_argument('--threads', type=int, default=2)
    parser.add_argument('--beam-short', type=int, default=2)
    parser.add_argument('--beam-long', type=int, default=5)
    parser.add_argument('--lambda-file', type=Path, default=None)
    parser.add_argument('--no-scoring', action='store_true')
    parser.add_argument('--collect-scores', action='store_true',
                        help='λ=0 也采集反向分数（开发数据采集用，排序仍按 λ）')
    parser.add_argument('--python', type=Path,
                        default=Path.home() / 'Library/Caches/Gogaku/models/small100-gate/venv-ct2/bin/python')
    parser.add_argument('--small100-root', type=Path,
                        default=Path.home() / 'Library/Caches/Gogaku/models/small100-gate')
    parser.add_argument('--quickmt-root', type=Path,
                        default=Path.home() / 'Library/Caches/Gogaku/models/quickmt-speed')
    parser.add_argument('--dylib', type=Path, default=ROOT / '.build/core/libgogaku_core.dylib')
    parser.add_argument('--output-dir', type=Path,
                        default=PROBES / 'results/translation-strategy-dev')
    parser.add_argument('--allow-short-run', action='store_true')
    parser.add_argument('--force', action='store_true')
    args = parser.parse_args()

    if args.rounds < 5 and not args.allow_short_run:
        parser.error('formal runs need --rounds >= 5; use --allow-short-run for dev collection')
    if not args.python.is_file():
        parser.error('worker python missing: %s' % args.python)

    benchmark = load_benchmark_module()
    by_suite = load_cases(args.cases, benchmark)
    cases = [case for name in by_suite for case in by_suite[name]]
    for name, expected in EXPECTED.items():
        if name not in by_suite or expected['total'] is None:
            continue
        if len(by_suite[name]) != expected['total']:
            raise SystemExit('%s: loaded %d cases, expected %d'
                             % (name, len(by_suite[name]), expected['total']))

    lambdas = dict(strategy.DEFAULT_LAMBDA)
    freeze = None
    if args.lambda_file:
        freeze = json.loads(args.lambda_file.read_text())
        frozen = freeze.get('lambda', {})
        lambdas.update({k: float(v) for k, v in frozen.items()})
        policy = freeze.get('policy', {})
        for key, expected_hash in policy.items():
            path = freeze.get('policyPaths', {}).get(key)
            if not path:
                continue
            actual = sha256_file(ROOT / path)
            if actual != expected_hash:
                raise SystemExit('frozen policy mismatch for %s: %s != %s'
                                 % (key, actual, expected_hash))
        print('using frozen lambdas: %s' % lambdas)
    if args.no_scoring:
        lambdas = {'en-zh': 0.0, 'zh-en': 0.0}
    needs_scorer = (not args.no_scoring) and (args.collect_scores or any(
        value > 0 for value in lambdas.values()))

    output_dir = args.output_dir.resolve()
    if output_dir.exists() and any(output_dir.iterdir()):
        if not args.force:
            parser.error('output dir is not empty: %s (use --force)' % output_dir)
        shutil.rmtree(output_dir)
    output_dir.mkdir(parents=True, exist_ok=True)

    run_id = datetime.datetime.now(datetime.timezone.utc).strftime('%Y%m%dT%H%M%SZ')
    requests_path = output_dir / 'requests.jsonl'
    run_path = output_dir / 'run.json'
    run = {
        'schemaVersion': 1,
        'runId': run_id,
        'startedAt': now_utc(),
        'stage': 'final' if 'final' in by_suite else 'dev',
        'parameters': {
            'cases': args.cases,
            'rounds': args.rounds,
            'threads': args.threads,
            'lambdas': lambdas,
            'scoring': needs_scorer,
            'collectScores': args.collect_scores,
            'beamShort': args.beam_short,
            'beamLong': args.beam_long,
            'workerPython': str(args.python),
            'small100Root': str(args.small100_root),
            'quickmtRoot': str(args.quickmt_root),
            'hardeningDylib': str(args.dylib),
            'lambdaFile': str(args.lambda_file) if args.lambda_file else None,
        },
        'policy': {
            'resources': strategy.Resources().manifest,
            'templatesVersion': strategy.Templates().version,
            'brandsVersion': strategy.Brands().version,
            'strategyModule': sha256_file(PROBES / 'translation_strategy.py'),
            'worker': sha256_file(PROBES / 'translation-backend-worker.py'),
            'dylib': sha256_file(args.dylib),
        },
        'caseHashes': case_hashes(by_suite),
        'caseCounts': {name: {'total': len(items),
                              'byDirection': {d: sum(1 for c in items if c['direction'] == d)
                                              for d in ('en-zh', 'zh-en')}}
                       for name, items in by_suite.items()},
        'hardeningCounts': {},
        'environment': {'platform': sys.platform, 'machine': os.uname().machine,
                        'python': sys.version},
        'workers': {},
        'rounds': [],
    }
    for case in cases:
        key = case['timingBucket']
        run['hardeningCounts'][key] = run['hardeningCounts'].get(key, 0) + 1
    benchmark.atomic_write(run_path, run)

    # small100 生成进程
    generate_worker = benchmark.Worker(
        'small100',
        {'backend': 'small100', 'root': args.small100_root, 'direction': 'both'},
        args.python, output_dir / 'worker-small100.stderr.log', args.threads, 'int8',
        args.beam_short, 256)
    run['workers']['small100'] = {
        'ready': generate_worker.ready,
        'stderrLog': str(output_dir / 'worker-small100.stderr.log'),
    }

    scorer_worker = None
    if needs_scorer:
        scorer_worker = start_scorer(args, output_dir, benchmark)
        run['workers']['quickmt-scorer'] = {
            'ready': scorer_worker['ready'],
            'stderrLog': str(output_dir / 'worker-scorer.stderr.log'),
        }
    benchmark.atomic_write(run_path, run)

    structure = strategy.Structure(args.dylib)
    pipeline = strategy.Pipeline(
        strategy.Resources(), strategy.Templates(), strategy.Brands(), structure,
        generate=lambda request: generate_request(generate_worker, request),
        score=lambda payload: score_request(scorer_worker, payload) if scorer_worker else (None, 0.0),
        lambdas=lambdas,
        score_always=args.collect_scores)

    # 预热（不计入延迟）
    warm = cases[:2]
    for case in warm:
        pipeline.translate(dict(case))

    sequence = 0
    try:
        with requests_path.open('w') as requests:
            for round_index in range(args.rounds):
                round_started = now_utc()
                order = list(cases)
                random.Random(9011 + round_index).shuffle(order)
                round_rows = 0
                for case in order:
                    sequence += 1
                    start_ns = time.perf_counter_ns()
                    try:
                        decision = pipeline.translate(case)
                        error = None
                    except Exception as failure:  # 单条失败不能中断整轮
                        decision = {'action': 'fallback-original', 'text': case['source'],
                                    'path': 'pipeline-error', 'reason': repr(failure),
                                    'candidates': [], 'stageMs': {}}
                        error = repr(failure)
                        if scorer_worker is not None and scorer_worker['worker'].dead:
                            scorer_worker = None
                    wait_ms = (time.perf_counter_ns() - start_ns) / 1e6
                    budget = strategy.BUDGETS.get(case['timingBucket'])
                    record = {
                        'schemaVersion': 1,
                        'runId': run_id,
                        'round': round_index + 1,
                        'sequence': sequence,
                        'caseId': case['id'],
                        'suite': case['suite'],
                        'direction': case['direction'],
                        'kind': case.get('kind'),
                        'timingBucket': case['timingBucket'],
                        'expectedAction': case['expectedAction'],
                        'source': case['source'],
                        'sourceSha256': hashlib.sha256(case['source'].encode('utf-8')).hexdigest(),
                        'reference': case.get('reference'),
                        'decision': decision,
                        'userWaitMs': wait_ms,
                        'budgetMs': budget,
                        'overBudgetMs': round(wait_ms - budget, 2) if budget and wait_ms > budget else None,
                        'error': error or (decision.get('generate') or {}).get('error'),
                        'lambda': lambdas,
                    }
                    requests.write(json.dumps(record, ensure_ascii=False) + '\n')
                    requests.flush()
                    round_rows += 1
                run['rounds'].append({'round': round_index + 1, 'startedAt': round_started,
                                      'finishedAt': now_utc(), 'rows': round_rows})
                benchmark.atomic_write(run_path, run)
                print('round %d/%d: %d requests' % (round_index + 1, args.rounds, round_rows),
                      flush=True)
    finally:
        run['small100StoppedPeakRssBytes'] = generate_worker.stop()
        if scorer_worker is not None:
            run['scorerStoppedPeakRssBytes'] = scorer_worker['worker'].stop()
        run['finishedAt'] = now_utc()
        run['requestCount'] = sequence
        run['expectedRequestCount'] = len(cases) * args.rounds
        run['completeRun'] = sequence == run['expectedRequestCount']
        benchmark.atomic_write(run_path, run)
    print('wrote %s and %s' % (requests_path, run_path), flush=True)
    return 0


def start_scorer(args, output_dir, benchmark):
    """启动 scoring-only quickmt worker（双向模型都加载）。"""
    import queue
    import subprocess
    import threading

    log_path = output_dir / 'worker-scorer.stderr.log'
    command = [
        str(args.python), '-u', str(PROBES / 'translation-backend-worker.py'),
        '--backend', 'quickmt',
        '--root', str(args.quickmt_root),
        '--direction', 'both',
        '--threads', str(args.threads),
        '--compute-type', 'int8',
        '--enable-scoring',
        '--scoring-only',
    ]
    log = log_path.open('w')
    process = subprocess.Popen(command, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                               stderr=log, text=True, bufsize=1, start_new_session=True)
    messages = queue.Queue()

    def reader():
        for line in process.stdout:
            messages.put(line)
        messages.put(None)

    threading.Thread(target=reader, daemon=True).start()
    line = messages.get(timeout=600)
    if line is None:
        raise SystemExit('scorer worker exited during load')
    ready = json.loads(line)
    if ready.get('event') != 'ready':
        raise SystemExit('scorer worker failed to load: %s' % ready)

    def request(payload):
        start = time.perf_counter_ns()
        process.stdin.write(json.dumps(payload, ensure_ascii=False) + '\n')
        process.stdin.flush()
        while True:
            message = messages.get(timeout=120)
            if message is None:
                raise RuntimeError('scorer worker exited')
            parsed = json.loads(message)
            if parsed.get('event') != 'score_result':
                continue
            return parsed, (time.perf_counter_ns() - start) / 1e6

    class Scorer:
        def __init__(self):
            self.ready = ready
            self.dead = False

        def score(self, payload):
            try:
                return request(payload)
            except Exception:
                self.dead = True
                raise

        def stop(self):
            peak = ready.get('peakRssBytes')
            if process.poll() is None:
                try:
                    process.stdin.write('{"event":"stop"}\n')
                    process.stdin.flush()
                    while True:
                        message = messages.get(timeout=20)
                        if message is None:
                            break
                        parsed = json.loads(message)
                        if parsed.get('event') == 'stopped':
                            peak = parsed.get('peakRssBytes', peak)
                            break
                    process.wait(timeout=20)
                except Exception:
                    pass
            if process.poll() is None:
                process.kill()
            log.close()
            return peak

    return {'worker': Scorer(), 'ready': ready}


def generate_request(worker, request):
    rows, ipc_ms = worker.request([request], 'strategy')
    return (rows[0] if rows else {'error': 'missing result'}), ipc_ms


def score_request(scorer, payload):
    scores, ipc_ms = scorer['worker'].score({'event': 'score', **payload})
    return scores.get('scores') or [], ipc_ms


if __name__ == '__main__':
    sys.exit(main())
