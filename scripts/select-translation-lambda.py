#!/usr/bin/env python3
"""离线选择反向评分权重 λ：用一次开发数据采集的候选＋分数，不重复模型推理。

规则（docs/translation-strategy-decision.md，运行前固定）：
  1. 关键风险错误更少；
  2. 合格译文覆盖更高；
  3. λ 更小（更少开销）。
两个方向分别选择；λ=0 表示该方向禁用评分调用。

用法：
  python3 scripts/select-translation-lambda.py \
      --requests probes/results/translation-strategy-dev/requests.jsonl \
      --labels probes/results/translation-strategy-dev/labels.json \
      --output probes/results/translation-strategy-dev/lambda-selection.json
"""
import argparse
import json
import sys
from pathlib import Path

LAMBDAS = (0.0, 0.25, 0.5, 1.0)
DIRECTIONS = ('en-zh', 'zh-en')


def chosen(candidates, lam):
    accepted = [c for c in candidates if c.get('accepted')]
    if not accepted:
        return None
    def key(candidate):
        forward = candidate.get('forwardScore') or 0.0
        reverse = candidate.get('reverseScore')
        if lam > 0 and reverse is None:
            return (forward, forward)
        return (forward + lam * (reverse or 0.0), forward)
    return max(accepted, key=key)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--requests', type=Path, required=True)
    parser.add_argument('--labels', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()

    rows = {}
    for line in args.requests.read_text(encoding='utf-8').splitlines():
        row = json.loads(line)
        rows[row['caseId']] = row
    labels = json.loads(args.labels.read_text(encoding='utf-8'))
    verdicts = labels['verdicts']

    problems = []
    for case_id, items in verdicts.items():
        row = rows.get(case_id)
        if row is None:
            problems.append('label for unknown case %s' % case_id)
            continue
        accepted = [c for c in row['decision']['candidates'] if c.get('accepted')]
        if len(accepted) != len(items):
            problems.append('%s: %d accepted candidates but %d verdicts'
                            % (case_id, len(accepted), len(items)))
    unlabelled = [case_id for case_id, row in rows.items()
                  if case_id not in verdicts and row['suite'] == 'risk']
    if unlabelled:
        problems.append('风险集未标注：%s' % unlabelled)
    labelled_model_paths = sum(1 for case_id in verdicts
                               if rows[case_id]['decision']['path'] == 'model')
    model_paths = sum(1 for row in rows.values()
                      if row['decision']['path'] == 'model')
    print('已标注 %d 条用例（其中模型路径 %d），开发集模型路径共 %d 条；'
          'λ 只在标注子集上选择。' % (len(verdicts), labelled_model_paths, model_paths))
    if problems:
        print('label coverage failed:')
        for problem in problems:
            print('  - ' + problem)
        return 2

    def evaluate(lam, direction):
        critical_errors = 0
        coverage = 0
        applicable = 0
        details = []
        for case_id, items in verdicts.items():
            row = rows[case_id]
            if row['direction'] != direction:
                continue
            accepted = [c for c in row['decision']['candidates'] if c.get('accepted')]
            if not accepted:
                continue
            pick = chosen(row['decision']['candidates'], lam)
            index = accepted.index(pick)
            verdict = items[index]['verdict']
            applicable += 1
            if verdict == 'pass':
                coverage += 1
            elif row['suite'] == 'risk':
                critical_errors += 1
            details.append({'caseId': case_id, 'suite': row['suite'], 'index': index,
                            'verdict': verdict, 'text': pick['text']})
        return {'lambda': lam, 'applicable': applicable, 'criticalErrors': critical_errors,
                'coverage': coverage,
                'coverageRate': round(coverage / applicable, 4) if applicable else None,
                'details': details}

    report = {'schemaVersion': 1, 'lambdas': list(LAMBDAS),
              'rule': '关键风险错误更少 → 合格译文覆盖更高 → λ 更小', 'directions': {}}
    for direction in DIRECTIONS:
        table = [evaluate(lam, direction) for lam in LAMBDAS]
        best = sorted(table, key=lambda row: (row['criticalErrors'], -row['coverage'],
                                              row['lambda']))[0]
        report['directions'][direction] = {'table': table, 'selected': best['lambda'],
                                           'selectedRow': {k: v for k, v in best.items()
                                                           if k != 'details'}}
        print('%s: ' % direction + ' | '.join(
            'λ=%.2f 风险错=%d 覆盖=%d/%d' % (row['lambda'], row['criticalErrors'],
                                            row['coverage'], row['applicable'])
            for row in table) + ' → 选中 λ=%.2f' % best['lambda'])
    report['lambda'] = {direction: report['directions'][direction]['selected']
                        for direction in DIRECTIONS}
    args.output.write_text(json.dumps(report, ensure_ascii=False, indent=1) + '\n',
                           encoding='utf-8')
    print('wrote %s' % args.output)
    return 0


if __name__ == '__main__':
    sys.exit(main())
