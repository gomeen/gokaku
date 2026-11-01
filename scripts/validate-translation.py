#!/usr/bin/env python3
"""冻结每方向100条保留集，或执行 Apple 已安装资源的盲测；不会安装语言包。"""
import argparse
import collections
import hashlib
import json
from pathlib import Path
import platform
import select
import subprocess
import sys
import time
import uuid

ROOT = Path(__file__).resolve().parent.parent
CORPUS = ROOT / 'validation/translation-holdout.tsv'
FROZEN = ROOT / 'validation/translation-holdout.json'

def freeze():
    if FROZEN.exists(): raise SystemExit('保留集已经冻结；不覆盖既有样例或参考。')
    rows = []
    for line in CORPUS.read_text().splitlines():
        if not line or line.startswith('#'): continue
        kind, english, chinese = line.split('|')
        rows.append((kind, english, chinese))
    assert len(rows) == 100, len(rows)
    cases = []
    for direction in ['enToZh', 'zhToEn']:
        for n, (kind, english, chinese) in enumerate(rows):
            source, reference = (english, chinese) if direction == 'enToZh' else (chinese, english)
            action = 'preserve' if kind in {'protected', 'typo'} else 'translate'
            if action == 'preserve': reference = source
            cases.append({'id': f'{direction}-{n+1:03d}', 'direction': direction, 'kind': kind, 'source': source, 'reference': reference, 'expectedAction': action})
    manifest = {'schemaVersion': 1, 'sourceSha256': hashlib.sha256(CORPUS.read_bytes()).hexdigest(),
                'notes': '每方向100条。前95条是90个互译语义场景加5个字面保留场景；最后5条为两个方向独立的应保留输入，不是互译词对。参考不是唯一合法措辞；最终语义由用户确认。冻结时未查看后端输出。', 'cases': cases}
    FROZEN.write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + '\n')
    print(json.dumps({'counts': dict(collections.Counter(c['direction'] for c in cases)), 'sha256': hashlib.sha256(FROZEN.read_bytes()).hexdigest()}))

def run(helper, output_directory):
    output_directory.mkdir(parents=True, exist_ok=True)
    status = json.loads(subprocess.check_output([str(helper), '--status'], text=True, timeout=30))
    frozen = json.loads(FROZEN.read_text())
    report = {'backend': 'apple-system-default', 'resourceStatus': status, 'os': platform.platform(),
              'holdoutSha256': hashlib.sha256(FROZEN.read_bytes()).hexdigest(),
              'quality': 'requires_user_review', 'offline': 'not_verified_shared_system_service', 'performance': 'not_formal_acceptance'}
    if any(status.get(d) != 'installed' for d in ['enToZh', 'zhToEn']):
        report['state'] = 'blocked_missing_system_resources'
        (output_directory / 'report.json').write_text(json.dumps(report, ensure_ascii=False, indent=2) + '\n')
        print('阻塞：请先通过 Gogaku 设置中的显式系统授权入口安装中英语言资源。')
        return 2
    cases = list(frozen['cases'])
    # 同时复用既有32条固定风险回归；不看输出修改标签。
    for case in json.loads((ROOT / 'probes/translation-cases.json').read_text()):
        cases.append({'id': 'risk-' + case['id'], 'direction': 'enToZh' if case['direction'] == 'en-zh' else 'zhToEn', 'source': case['source'], 'reference': case['review'], 'kind': case['kind'], 'expectedAction': 'review'})
    # 固定盲测顺序，不向 backend 发送参考译文。
    cases.sort(key=lambda c: hashlib.sha256(c['id'].encode()).digest())
    results = []
    process = None
    try:
        for case in cases:
            if process is None:
                process = subprocess.Popen([str(helper)], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
            request = {'protocolVersion': 1, 'id': str(uuid.uuid4()), 'stamp': {'session': str(uuid.uuid4()), 'focus': 1, 'composition': str(uuid.uuid4()), 'revision': 1, 'mode': 'learning', 'direction': case['direction']}, 'sourceID': case['id'], 'source': case['source'], 'resource': 'apple-default:' + status['os']}
            start = time.perf_counter()
            process.stdin.write(json.dumps(request, ensure_ascii=False).encode() + b'\n'); process.stdin.flush()
            if not select.select([process.stdout], [], [], 10)[0]:
                result = {'error': 'timeout', 'target': None}
                process.kill(); process.wait(); process = None
            else:
                line = process.stdout.readline(65_537)
                try:
                    result = json.loads(line)
                    assert uuid.UUID(result['id']) == uuid.UUID(request['id']) and result['source'] == case['source']
                except Exception: result = {'error': 'invalid_response', 'target': None}
            results.append({'id': case['id'], 'source': case['source'], 'direction': case['direction'], 'target': result.get('target'), 'error': result.get('error'), 'wallMilliseconds': (time.perf_counter() - start) * 1000, 'inferenceMilliseconds': result.get('milliseconds'), 'review': 'pending'})
            (output_directory / 'outputs.json').write_text(json.dumps(results, ensure_ascii=False, indent=2) + '\n')
    finally:
        if process:
            process.kill(); process.wait()
    report['state'] = 'awaiting_user_language_review'
    report['count'] = len(results)
    (output_directory / 'report.json').write_text(json.dumps(report, ensure_ascii=False, indent=2) + '\n')
    blind = ['# 翻译盲测输出', '', '先审阅输出，再对照单独参考表。空输出、超时、重复或意义破坏计失败。', '']
    references = ['# 冻结参考与应保留场景', '']
    by_id = {c['id']: c for c in cases}
    for result in results:
        blind += [f"## {result['id']}", '', result['source'], '', result['target'] or f"失败：{result['error']}", '', '语义可用：待用户确认', '']
        case = by_id[result['id']]
        references += [f"- {case['id']}：{case['expectedAction']}；{case['reference']}"]
    (output_directory / 'blind-outputs.md').write_text('\n'.join(blind))
    (output_directory / 'references.md').write_text('\n'.join(references) + '\n')
    return 0

if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--freeze', action='store_true')
    parser.add_argument('--helper', type=Path, default=ROOT / 'dist/Gogaku.app/Contents/Helpers/GogakuTranslator')
    parser.add_argument('--output', type=Path, default=ROOT / 'local/translation-validation')
    args = parser.parse_args()
    if args.freeze: freeze()
    else: sys.exit(run(args.helper.resolve(), args.output))
