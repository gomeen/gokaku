#!/usr/bin/env python3
"""汇总策略验收结果：按方向统计合格覆盖率、放行精度、回退率与延迟门槛。

输入：
  --run <dir>       benchmark-translation-strategy.py 的输出目录（requests.jsonl + run.json）
  --labels <file>   最终验收语义标注（对每一条放行译文逐条判定 pass/fail）
  --output <file>   验收报告 JSON

判定规则（docs/translation-strategy-decision.md，与标注文件同时冻结）：
  - 应译样例的合格译文数／全部应译数 ≥ 95%（每方向单独）；
  - 放行、回退、错误放行分开统计，不能用资源命中掩盖模型路径；
  - 任一放行结果缺少语义标注即判 blocked，不因为缺数据而通过；
  - 固定风险集不得有未处置的意义破坏进入候选；
  - 短表达 p95 ≤ 500ms、短句 p95 ≤ 2s，超预算请求必须保留在案。
"""
import argparse
import json
import sys
from pathlib import Path

GATE = 0.95
BUDGETS = {'short-expression': 500.0, 'short-sentence': 2000.0}
DIRECTIONS = ('en-zh', 'zh-en')


def percentile(values, fraction):
    if not values:
        return None
    ordered = sorted(values)
    index = min(len(ordered) - 1, max(0, int(round(fraction * (len(ordered) - 1)))))
    return round(ordered[index], 1)


def load_rows(path):
    return [json.loads(line) for line in Path(path).read_text(encoding='utf-8').splitlines()]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--run', type=Path, required=True)
    parser.add_argument('--labels', type=Path, required=True)
    parser.add_argument('--checks', type=Path,
                        default=Path('probes/translation-risk-checks.json'))
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()

    run = json.loads((args.run / 'run.json').read_text())
    rows = load_rows(args.run / 'requests.jsonl')
    labels = json.loads(args.labels.read_text(encoding='utf-8'))
    verdicts = labels.get('verdicts', {})
    if not run.get('completeRun'):
        print('run is incomplete (%s/%s requests) — refusing to report'
              % (run.get('requestCount'), run.get('expectedRequestCount')))
        return 2

    # 同一用例跨轮次必须给出相同决策，否则「一次上屏」的行为不可复现。
    by_case = {}
    unstable = []
    for row in rows:
        key = row['caseId']
        signature = (row['decision'].get('action'), row['decision'].get('text'),
                     row['decision'].get('path'), row['decision'].get('reason'))
        by_case.setdefault(key, []).append(signature)
    for key, signatures in by_case.items():
        if len(set(signatures)) > 1:
            unstable.append({'caseId': key, 'variants': len(set(signatures))})

    suites = {}
    missing_labels = []
    report = {'schemaVersion': 1, 'runId': run.get('runId'), 'lambda': run['parameters']['lambdas'],
              'freeze': run['parameters'].get('lambdaFile'), 'gate': GATE,
              'unstableDecisions': unstable, 'directions': {}, 'risk': {}, 'probes': {},
              'latency': {}, 'paths': {}}

    checks = json.loads(args.checks.read_text())['cases']

    for direction in DIRECTIONS:
        # 运行时保留也算在这 100 条应译里（保留＝未提供合格译文），否则覆盖被高估。
        final_rows = [row for row in rows
                      if row['suite'] == 'final' and row['direction'] == direction
                      and not row['caseId'].startswith('probe-')]
        # 每轮都有同一批用例；先取第一轮的决策做质量判定。
        first_round = {}
        for row in final_rows:
            first_round.setdefault(row['caseId'], row)
        scored = len(first_round)
        released = 0
        qualified = 0
        path_counts = {}
        failures = []
        for case_id, row in sorted(first_round.items()):
            decision = row['decision']
            path = decision.get('path') or 'unknown'
            path_counts[path] = path_counts.get(path, 0) + 1
            if decision.get('action') == 'candidate':
                released += 1
                entry = verdicts.get(case_id)
                if not entry or entry.get('verdict') not in ('pass', 'fail'):
                    missing_labels.append(case_id)
                    continue
                if entry['verdict'] == 'pass':
                    qualified += 1
                else:
                    failures.append({'caseId': case_id, 'text': decision.get('text'),
                                     'reference': row.get('reference'),
                                     'path': path, 'note': entry.get('note')})
            else:
                entry = verdicts.get(case_id) or {}
                if not entry.get('fallbackJustified', True):
                    failures.append({'caseId': case_id, 'text': None,
                                     'reference': row.get('reference'), 'path': path,
                                     'note': '回退未被标注为合理：%s / %s'
                                             % (decision.get('reason'), entry.get('note'))})
        report['directions'][direction] = {
            'scored': scored,
            'released': released,
            'qualified': qualified,
            'coverageRate': round(qualified / scored, 4) if scored else None,
            'releaseRate': round(released / scored, 4) if scored else None,
            'releasePrecision': round(qualified / released, 4) if released else None,
            'fallbackRate': round((scored - released) / scored, 4) if scored else None,
            'errorReleased': released - qualified,
            'gatePassed': scored > 0 and qualified / scored >= GATE,
            'pathCounts': path_counts,
            'failures': failures,
        }

    # 固定风险集：不得有意义破坏进入候选。
    risk_rows = {}
    for row in rows:
        if row['suite'] != 'risk':
            continue
        risk_rows.setdefault(row['caseId'], row)
    risk_violations = []
    risk_preserved_expected = []
    for case_id, row in sorted(risk_rows.items()):
        decision = row['decision']
        if row.get('expectedAction') == 'preserve':
            entry = {'caseId': case_id, 'action': decision.get('action'),
                     'path': decision.get('path')}
            risk_preserved_expected.append(entry)
            # 错拼/未知输入被当成正常输入送去翻译，等于把猜测当可靠候选。
            if decision.get('action') == 'candidate':
                risk_violations.append({'caseId': case_id, 'text': decision.get('text'),
                                        'reason': 'typo-or-unknown was translated',
                                        'label': (verdicts.get(case_id) or {}).get('verdict')})
            continue
        if decision.get('action') == 'preserve':
            risk_violations.append({'caseId': case_id,
                                    'reason': 'preserved: ' + str(decision.get('reason'))})
            continue
        if decision.get('action') != 'candidate':
            continue
        text = (decision.get('text') or '').lower()
        check = checks.get(case_id) or {}
        missing = [needle for needle in check.get('requireAll', []) if needle.lower() not in text]
        for group in check.get('requireAny', []):
            if not any(needle.lower() in text for needle in group):
                missing.append('one-of:' + '|'.join(group))
        forbidden = [needle for needle in check.get('forbid', []) if needle.lower() in text]
        label = (verdicts.get(case_id) or {}).get('verdict')
        if missing or forbidden or label == 'fail':
            risk_violations.append({'caseId': case_id, 'text': decision.get('text'),
                                    'missing': missing, 'forbidden': forbidden,
                                    'label': label})
    report['risk'] = {'total': len(risk_rows), 'violations': risk_violations,
                      'preservedExpected': risk_preserved_expected,
                      'gatePassed': not risk_violations}

    # 运行时保留探针（不参与 95% 指标）
    probe_rows = [row for row in rows if row['caseId'].startswith('probe-')]
    probe_first = {}
    for row in probe_rows:
        probe_first.setdefault(row['caseId'], row)
    probe_summary = {}
    for case_id, row in sorted(probe_first.items()):
        decision = row['decision']
        probe_summary[case_id] = {
            'source': row['source'],
            'action': decision.get('action'),
            'path': decision.get('path'),
            'reason': decision.get('reason'),
            'text': decision.get('text'),
        }
    actions = {}
    for entry in probe_summary.values():
        actions[entry['action']] = actions.get(entry['action'], 0) + 1
    report['probes'] = {'cases': probe_summary, 'actions': actions}

    # 延迟：五轮全部请求都在案；分桶 p95 与超预算记录。
    for bucket, budget in BUDGETS.items():
        waits = [row['userWaitMs'] for row in rows if row['timingBucket'] == bucket]
        over = [{'caseId': row['caseId'], 'round': row['round'],
                 'waitMs': round(row['userWaitMs'], 1), 'overMs': row['overBudgetMs'],
                 'path': row['decision'].get('path')}
                for row in rows if row['overBudgetMs'] and row['timingBucket'] == bucket]
        report['latency'][bucket] = {
            'budgetMs': budget,
            'count': len(waits),
            'p50': percentile(waits, 0.50),
            'p95': percentile(waits, 0.95),
            'max': round(max(waits), 1) if waits else None,
            'overBudget': len(over),
            'overBudgetRecords': over[:40],
            'gatePassed': bool(waits) and percentile(waits, 0.95) <= budget,
        }
    report['paths'] = {}
    for row in rows:
        path = row['decision'].get('path') or 'unknown'
        entry = report['paths'].setdefault(path, {'count': 0, 'waits': []})
        entry['count'] += 1
        entry['waits'].append(row['userWaitMs'])
    for entry in report['paths'].values():
        entry['p95'] = percentile(entry.pop('waits'), 0.95)

    report['labelCoverage'] = {'missing': missing_labels,
                               'labelled': len(verdicts),
                               'blocked': bool(missing_labels)}
    report['gates'] = {
        'quality': all(report['directions'][d]['gatePassed'] for d in DIRECTIONS),
        'risk': report['risk']['gatePassed'],
        'latency': all(report['latency'][b]['gatePassed'] for b in BUDGETS),
        'labels': not missing_labels,
        'stable': not unstable,
    }
    report['passed'] = all(report['gates'].values())
    args.output.write_text(json.dumps(report, ensure_ascii=False, indent=1) + '\n',
                           encoding='utf-8')
    for direction in DIRECTIONS:
        entry = report['directions'][direction]
        print('%s 合格 %d/%d (%.1f%%) 放行 %d 回退 %d 错误放行 %d 精度 %s'
              % (direction, entry['qualified'], entry['scored'],
                 100 * (entry['coverageRate'] or 0), entry['released'],
                 entry['scored'] - entry['released'], entry['errorReleased'],
                 entry['releasePrecision']))
    for bucket, entry in report['latency'].items():
        print('%s p95 %sms（预算 %dms，超预算 %d 条）'
              % (bucket, entry['p95'], entry['budgetMs'], entry['overBudget']))
    print('gates', report['gates'], 'passed', report['passed'])
    if missing_labels:
        print('missing labels: %d cases — verdict blocked' % len(missing_labels))
        return 2
    return 0 if report['passed'] else 1


if __name__ == '__main__':
    sys.exit(main())
