"""验证策略的单一来源；仅处理传入的数据，不运行命令或读取系统状态。"""
from __future__ import annotations

import re

POLICY_VERSION = 2
PASS, FAIL, SKIP, BLOCK = 'passed', 'failed', 'skipped', 'blocked'
STATUSES = (PASS, FAIL, SKIP, BLOCK)
PROFILE_CHECKS = {
    'fast': (
        ('version', True), ('resources', True), ('core-tests', True),
        ('swift-tests', True), ('translation-data', True),
        ('verification-contracts', True), ('delivery-contracts', True),
    ),
    'release': (
        ('version', True), ('resources', True), ('core-tests', True),
        ('swift-tests', True), ('translation-data', True),
        ('verification-contracts', True), ('clean-build', True),
        ('bundle-check', True), ('quality', True), ('render', True),
        ('data-reliability', True), ('delivery-contracts', True),
        ('asan-ubsan', True), ('install-preflight', False),
    ),
    'host': (
        ('host-plan', True), ('host-identity', True),
        ('host-matrix-round-1', True), ('host-matrix-round-2', True),
        ('orca-shift', True), ('performance', True), ('stability', True),
        ('native-gui', True),
    ),
}


class VerificationError(ValueError):
    pass


def validate_checks(profile, checks):
    """严格核对完整档位清单，返回重算的 gate；不信任调用者的 required。"""
    if not isinstance(profile, str) or profile not in PROFILE_CHECKS:
        raise VerificationError('未知验证 profile')
    if not isinstance(checks, list):
        raise VerificationError('checks 必须是列表')
    policy = dict(PROFILE_CHECKS[profile])
    seen = set()
    for check in checks:
        if not isinstance(check, dict) or not {'name', 'required', 'status'} <= check.keys():
            raise VerificationError('检查项结构不完整')
        name, required, status = check['name'], check['required'], check['status']
        if not isinstance(name, str) or name not in policy or name in seen:
            raise VerificationError('检查项未知或重复')
        seen.add(name)
        if type(required) is not bool or required != policy[name]:
            raise VerificationError('检查项 required 与策略不符')
        if not isinstance(status, str) or status not in STATUSES:
            raise VerificationError('检查项 status 非法')
        if 'detail' in check and not isinstance(check['detail'], str):
            raise VerificationError('检查项 detail 必须是文本')
        if 'durationMs' in check and (type(check['durationMs']) is not int or check['durationMs'] < 0):
            raise VerificationError('检查项 durationMs 必须是非负整数')
        if 'evidence' in check and check['evidence'] is not None and not isinstance(check['evidence'], str):
            raise VerificationError('检查项 evidence 必须是路径或 null')
    if seen != policy.keys():
        raise VerificationError('检查清单缺少策略项：' + ', '.join(sorted(policy.keys() - seen)))
    statuses = {check['name']: check['status'] for check in checks}
    bad = [name for name, required in PROFILE_CHECKS[profile] if required and statuses[name] != PASS]
    return {'passed': not bad, 'notPassed': bad}


def summarize_checks(checks):
    """输入应先经 validate_checks 核对。"""
    return {status: sum(check['status'] == status for check in checks) for status in STATUSES}


def validate_ctest_result(returncode: int, output: str) -> list[str]:
    """返回 problems（空列表＝通过）；要求正数量且逐项 Passed 的完整输出。

    面向 ctest --output-on-failure 的标准文本输出；未知格式宁可拒绝，不能用
    退出码 0 或孤立的 100% 字样作为覆盖证据。调用者应先合并 stdout/stderr。
    """
    if type(returncode) is not int or not isinstance(output, str):
        return ['CTest 结果类型非法']
    if returncode != 0:
        return [f'ctest 未完成（exit={returncode}）']
    if re.search(r'\b(?:skipped|not\s+run|no\s+tests|disabled)\b|\bskip\s*:', output, re.IGNORECASE):
        return ['CTest 存在跳过／未执行的测试']
    # CTest 4 的全绿汇总省略「0 tests failed」；同时支持旧版格式。
    summaries = re.findall(r'^\s*(\d+)% tests passed(?:,\s*(\d+) tests failed)? out of (\d+)\s*$',
                           output, re.MULTILINE)
    if len(summaries) != 1:
        return ['CTest 缺少唯一的完整汇总']
    percent, failed, total = (int(summaries[0][0]), int(summaries[0][1] or 0), int(summaries[0][2]))
    if total == 0:
        return ['CTest 未执行任何测试']
    if percent != 100 or failed != 0:
        return ['CTest 未全过']
    # 不接受只打印汇总的伪完成输出；序号与总数必须覆盖同一轮完整执行。
    passed = re.findall(r'^\s*(\d+)\s*/\s*(\d+)\s+Test\s+#(\d+):[^\n]*'
                        r'\.{2,}\s+Passed\s+\d+(?:\.\d+)?\s+sec\s*$',
                        output, re.MULTILINE)
    if (len(passed) != total or {int(n) for n, _, _ in passed} != set(range(1, total + 1))
            or any(int(count) != total for _, count, _ in passed)
            or len({int(test) for _, _, test in passed}) != total):
        return ['CTest 逐项通过记录与汇总不符']
    return []
