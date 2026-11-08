#!/usr/bin/env python3
"""验证入口的离线合同测试；不安装、不联网、不注入按键。"""
import contextlib
import copy
import hashlib
import importlib.util
import io
import json
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO / 'scripts'))


def load(name, file):
    spec = importlib.util.spec_from_file_location(name, REPO / 'scripts' / file)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


verify = load('verification_entry', 'verify.py')
build = load('verification_build', 'build.py')


class VerificationTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='gogaku-verification-')
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.meta = {'version': '0.1.0-dev.1', 'buildNumber': 1}
        (self.root / 'version.json').write_text(json.dumps(self.meta))
        self.ctx = verify.Ctx.__new__(verify.Ctx)
        self.ctx._dir = self.root
        self.ctx['jobs'] = 2
        self.ctx['quick'] = False
        self.ctx['yes'] = True
        self.ctx['core_dir'] = self.root / 'build-core'
        self.addCleanup(verify.set_channel, 'stable')

    def gui_fixture(self):
        image = self.root / 'screen.png'
        image.write_bytes(b'test screenshot fixture; not real GUI evidence')
        expected = {'commit': 'a' * 40, 'sourceSha256': 'b' * 64,
                    'testSha256': 'c' * 64, 'version': self.meta,
                    'channel': 'stable', 'installedSHA256': 'd' * 64}
        report = {**expected, 'pass': True, 'screens': [
            {'page': page, 'size': list(size), 'appearance': appearance, 'passed': True,
             'screenshot': image.name, 'screenshotSha256': hashlib.sha256(image.read_bytes()).hexdigest()}
            for page in verify.GUI_PAGES for size in verify.GUI_SIZES
            for appearance in verify.GUI_APPEARANCES]}
        return report, expected

    def test_gui_complete_current_matrix(self):
        report, expected = self.gui_fixture()
        self.assertEqual(len(report['screens']), 28)
        self.assertEqual(verify.gui_problems(report, self.root, expected), [])

    def test_gui_rejects_old_identity_incomplete_duplicate_and_missing_image(self):
        report, expected = self.gui_fixture()
        for field in expected:
            value = copy.deepcopy(report)
            value[field] = 'old'
            self.assertTrue(verify.gui_problems(value, self.root, expected), field)
        for mutation in ('missing', 'duplicate', 'failed', 'escape', 'bad-hash', 'old-pages'):
            value = copy.deepcopy(report)
            if mutation == 'missing':
                value['screens'].pop()
            elif mutation == 'duplicate':
                value['screens'][-1] = copy.deepcopy(value['screens'][0])
            elif mutation == 'failed':
                value['screens'][0]['passed'] = False
            elif mutation == 'escape':
                value['screens'][0]['screenshot'] = '../outside.png'
            elif mutation == 'bad-hash':
                value['screens'][0]['screenshotSha256'] = '0' * 64
            else:
                value.pop('screens')
                value['pages'] = ['anything']
            self.assertTrue(verify.gui_problems(value, self.root, expected), mutation)
        (self.root / 'screen.png').unlink()
        self.assertTrue(verify.gui_problems(report, self.root, expected))

    def test_installed_identity_is_channel_specific_and_source_bound(self):
        apps = [self.root / 'Gogaku Dev.app', self.root / 'Gogaku Settings Dev.app']
        for app, identifier in zip(apps, ('org.gogaku.inputmethod.dev', 'org.gogaku.settings.dev')):
            (app / 'Contents/Resources').mkdir(parents=True)
            (app / 'Contents/Info.plist').write_bytes(plistlib.dumps({
                'CFBundleIdentifier': identifier, 'CFBundleShortVersionString': '0.1.0',
                'CFBundleVersion': '1'}))
            (app / 'Contents/Resources/build-identity.json').write_text(json.dumps({
                'sourceSha256': 's', 'channel': 'dev', 'fullVersion': self.meta['version'], 'buildNumber': 1}))
        binary = apps[0] / 'Contents/MacOS/GogakuInput'
        binary.parent.mkdir()
        binary.write_bytes(b'dev-only fixture')
        with mock.patch.object(verify, 'CHANNEL', 'dev'), \
                mock.patch.object(verify, 'INSTALLED_INPUT_APP', apps[0]), \
                mock.patch.object(verify, 'INSTALLED_SETTINGS_APP', apps[1]), \
                mock.patch.object(verify, 'VERSION_FILE', self.root / 'version.json'), \
                mock.patch.object(verify, 'source_fingerprint', return_value='s'):
            _, problems, sha = verify._installed_identity(self.ctx)
            self.assertEqual(problems, [])
            self.assertEqual(sha, hashlib.sha256(binary.read_bytes()).hexdigest())
            (apps[1] / 'Contents/Resources/build-identity.json').write_text('{}')
            self.assertTrue(verify._installed_identity(self.ctx)[1])

    def run_main(self, profile, channel, runners, *, source=None):
        output = io.StringIO()
        report = self.root / 'report.json'
        with mock.patch.object(sys, 'argv', ['verify.py', '--profile', profile, '--channel', channel,
                                             '--yes', '--report', str(report)]), \
                mock.patch.object(verify, 'ROOT', self.root), \
                mock.patch.object(verify, 'VERSION_FILE', self.root / 'version.json'), \
                mock.patch.object(verify, 'EVIDENCE_DIR', self.root / 'evidence'), \
                mock.patch.object(verify, 'PROFILES', {profile: runners}), \
                mock.patch.object(verify, 'source_fingerprint', side_effect=source or ['s', 's']), \
                mock.patch.object(verify, 'test_fingerprint', return_value='t'), \
                mock.patch.object(verify, 'working_tree_dirty', return_value=True), \
                mock.patch.object(verify, 'sh', return_value=subprocess.CompletedProcess([], 0, 'a' * 40, '')), \
                contextlib.redirect_stdout(output):
            code = verify.main()
        return code, json.loads(report.read_text()), output.getvalue()

    def test_dev_host_never_starts_stable_probes(self):
        runners = [(name, required, mock.Mock(return_value=(verify.PASS, 'fixture', None)))
                   for name, required in verify.PROFILE_CHECKS['host']]
        code, report, _ = self.run_main('host', 'dev', runners)
        self.assertEqual(code, 1)
        self.assertTrue(all(row['status'] == verify.BLOCK for row in report['checks']))
        for _, _, runner in runners:
            runner.assert_not_called()

    def test_stale_installation_blocks_host_injection(self):
        runners = [(name, required, mock.Mock(return_value=(verify.PASS, 'fixture', None)))
                   for name, required in verify.PROFILE_CHECKS['host']]
        runners[1][2].return_value = verify.FAIL, 'old installation', None
        code, report, _ = self.run_main('host', 'stable', runners)
        self.assertEqual(code, 1)
        self.assertTrue(all(row['status'] == verify.BLOCK for row in report['checks'][2:]))
        for _, _, runner in runners[2:]:
            runner.assert_not_called()

    def test_identity_drift_cannot_bind_new_source_to_old_test_result(self):
        runners = [('version', True, lambda ctx: (verify.PASS, 'fixture', None))]
        code, report, _ = self.run_main('fast', 'dev', runners, source=['before', 'after'])
        self.assertEqual(code, 1)
        self.assertIs(report['runIdentityStable'], False)
        self.assertIs(report['gate']['passed'], False)
        self.assertEqual(report['sourceSha256'], 'before')

    def test_passing_profile_is_not_described_as_publish_ready(self):
        runners = [('version', True, lambda ctx: (verify.PASS, 'fixture', None))]
        code, report, output = self.run_main('fast', 'dev', runners)
        self.assertEqual(code, 0)
        self.assertEqual(report['artifacts'], {})
        self.assertIn('不能用于发布', output)
        self.assertNotIn('发布门槛：通过', output)

    def test_host_report_checks_each_verdict_and_identity(self):
        path = self.root / 'host.json'
        good = {'checks': [{'ok': True}], 'failures': 0,
                'inputSource': {'installedSHA256': 'sha'}, 'skipped': []}
        path.write_text(json.dumps(good))
        self.assertEqual(verify._host_json_problems(path, 'sha'), [])
        for change in ({'checks': [{'ok': False}]}, {'failures': False}, {'checks': []},
                       {'skipped': [{'host': 'missing'}]}, {'inputSource': {}}, {'inputSource': 'bad'}):
            path.write_text(json.dumps({**good, **change}))
            self.assertTrue(verify._host_json_problems(path, 'sha'))
        path.write_text('[]')
        self.assertTrue(verify._host_json_problems(path, 'sha'))

    def test_render_queries_macos_swiftpm_output(self):
        bin_path = self.root / 'macos/.build/test-triple/release'
        objects = bin_path / 'GogakuKit.build'
        objects.mkdir(parents=True)
        (bin_path / 'Modules').mkdir()
        (objects / 'kit.swift.o').touch()
        responses = [subprocess.CompletedProcess([], 0, str(bin_path) + '\n', ''),
                     subprocess.CompletedProcess([], 0, '', ''),
                     subprocess.CompletedProcess([], 0, ''.join(f'  ok   check {i}\n' for i in range(53))
                                                 + '候选窗渲染比对：53 项检查，失败 0 — PASS\n', '')]
        with mock.patch.object(verify, 'ROOT', self.root), \
                mock.patch.object(verify, 'sh', side_effect=responses) as sh:
            self.assertEqual(verify.check_render(self.ctx)[0], verify.PASS)
        self.assertEqual(sh.call_args_list[0].kwargs['cwd'], self.root / 'macos')
        command = sh.call_args_list[1].args[0]
        self.assertIn(str(bin_path / 'Modules'), command)
        self.assertIn(str(objects / 'kit.swift.o'), command)

    def test_render_rejects_empty_truncated_and_failed_output(self):
        bin_path = self.root / 'macos/.build/triple/release'
        objects = bin_path / 'GogakuKit.build'
        objects.mkdir(parents=True)
        (bin_path / 'Modules').mkdir()
        (objects / 'kit.swift.o').touch()
        for output in ('', '候选窗渲染比对：53 项检查，失败 0 — PASS\n',
                       '  ok   one\n候选窗渲染比对：1 项检查，失败 0 — PASS\n',
                       '  FAIL failed\n候选窗渲染比对：53 项检查，失败 1 — FAIL\n'):
            responses = [subprocess.CompletedProcess([], 0, str(bin_path), ''),
                         subprocess.CompletedProcess([], 0, '', ''),
                         subprocess.CompletedProcess([], 0, output, '')]
            with mock.patch.object(verify, 'sh', side_effect=responses):
                self.assertEqual(verify.check_render(self.ctx)[0], verify.FAIL, output)

    def host_fixture(self, strict):
        hosts, iterations = (verify.HOST_MATRIX_HOSTS.split(',') if strict else ['orca-pty']), 2
        fkr = verify._probe_module('first_key_regression')
        plan = fkr.build_plan(hosts, iterations)
        groups = [{'id': g['id'], 'iterations': iterations, 'warmup': 1, 'ran': 3,
                   'passed': 3, 'failed': 0} for g in plan['groups']]
        checks = [{'group': g['id'], 'phase': 'panel', 'ok': True} for g in groups]
        matrix = {'plan': {k: v for k, v in plan.items() if k != 'groups'},
                  'groups': groups, 'checks': checks, 'failures': 0}
        report = {'schema': 'gogaku.first-key-matrix.v1', **matrix,
                  'inputSource': {'installedSHA256': 'sha'}, 'skipped': [],
                  'panelState': {'enabled': True}}
        if strict:
            scenarios = verify._probe_module('validate-real-hosts').SCENARIOS
            targets = [f'{h}/{t}' for h in hosts for t in fkr.TARGETS[h]]
            report.update(schema='gogaku.real-host-matrix.v2', firstKeyMatrix=matrix,
                          hosts=targets, strictScenarios=[s['id'] for s in scenarios],
                          checks=checks + [{'check': t + ': ' + s['label'], 'ok': True}
                                           for t in targets for s in scenarios])
        evidence = self.root / 'round.jsonl'
        evidence.write_text(''.join(json.dumps({'group': g['id'], 'iteration': i, 'ok': True}) + '\n'
                                    for g in groups for i in range(3)))
        return report, hosts, iterations, evidence

    def test_host_requires_full_plan_iterations_and_raw_evidence(self):
        for strict in (False, True):
            report, hosts, iterations, evidence = self.host_fixture(strict)
            path = self.root / 'round.json'
            def problems(value):
                path.write_text(json.dumps(value))
                return verify._host_json_problems(path, 'sha', hosts=hosts, iterations=iterations,
                                                  evidence_path=evidence, strict=strict)
            self.assertEqual(problems(report), [])
            for change in ('one-check', 'missing-group', 'short-run', 'old-plan', 'no-panel', 'missing-host'):
                value = copy.deepcopy(report)
                matrix = value['firstKeyMatrix'] if strict else value
                if change == 'one-check':
                    matrix['checks'] = [{'ok': True}]
                elif change == 'missing-group':
                    matrix['groups'].pop()
                elif change == 'short-run':
                    matrix['groups'][0]['ran'] -= 1
                elif change == 'old-plan':
                    matrix['plan']['iterations'] = 1
                elif change == 'no-panel':
                    value['panelState']['enabled'] = False
                elif strict:
                    value['hosts'].pop()
                else:
                    continue
                self.assertTrue(problems(value), change)
            lines = evidence.read_text().splitlines()
            evidence.write_text('\n'.join(lines[:-1]) + '\n')
            self.assertTrue(problems(report))
            evidence.unlink()
            self.assertTrue(problems(report))

    def test_performance_recomputes_ten_thousand_samples_and_identity(self):
        probe = verify._probe_module('measure-imk-latency')
        samples = [{'callbackNs': 1, 'renderNs': 1, 'firstDisplayNs': 1, 'clockValid': True}
                   for _ in range(10000)]
        for i in range(0, 10000, 100):
            samples[i].update(firstDisplay=True, confirmationHidden=True, visibleAtReturn=False)
        path = self.root / 'samples.json'
        path.write_text(json.dumps(samples))
        report = {'schema': 'gogaku.imk-latency.v1', 'sampleCount': 10000, 'samplesFile': str(path),
                  'summary': probe.summarize(samples), 'loop': {'actualEvents': 10000, 'compositions': 100},
                  'coverage': {'measuredFirstDisplays': 100}, 'guardFailures': [],
                  'limitations': {'selectionToHostLatency': {'verifiable': True, 'p95Ns': 1}},
                  'inputSource': {'artifacts': [{'path': 'Contents/MacOS/GogakuInput', 'sha256': 'sha'}]}}
        report['acceptance'] = probe.evaluate_report(report)
        self.assertEqual(verify._performance_problems(report, path, 'sha'), [])
        for change in ('short-count', 'short-loop', 'old-summary', 'old-sha', 'fake-acceptance', 'wrong-path'):
            value = copy.deepcopy(report)
            if change == 'short-count':
                value['sampleCount'] = 0
            elif change == 'short-loop':
                value['loop']['actualEvents'] = 0
            elif change == 'old-summary':
                value['summary']['callbackNs']['p95'] = 0
            elif change == 'old-sha':
                value['inputSource']['artifacts'][0]['sha256'] = 'old'
            elif change == 'fake-acceptance':
                value['acceptance'] = {'passed': True}
            else:
                value['samplesFile'] = 'other.json'
            self.assertTrue(verify._performance_problems(value, path, 'sha'), change)
        samples[0]['callbackNs'] = 60_000_000
        path.write_text(json.dumps(samples))
        self.assertTrue(verify._performance_problems(report, path, 'sha'))
        path.write_text('[]')
        self.assertTrue(verify._performance_problems(report, path, 'sha'))
        path.unlink()
        self.assertTrue(verify._performance_problems(report, path, 'sha'))

    def test_real_ctest_skip_is_rejected_by_verifier_and_builder(self):
        source = self.root / 'shared/GogakuCore'
        source.mkdir(parents=True)
        (source / 'CMakeLists.txt').write_text(
            'cmake_minimum_required(VERSION 3.25)\nproject(SkipTest LANGUAGES NONE)\n'
            'enable_testing()\nadd_test(NAME skip COMMAND "' + sys.executable + '" -c "import sys;sys.exit(77)")\n'
            'set_tests_properties(skip PROPERTIES SKIP_RETURN_CODE 77)\n')
        with mock.patch.object(verify, 'ROOT', self.root):
            # sh 的默认 cwd 已绑定真实仓库；这里明确使用临时工程工作目录。
            real_sh = verify.sh
            with mock.patch.object(verify, 'sh', side_effect=lambda args, **kw: real_sh(args, cwd=self.root, **kw)):
                self.assertEqual(verify.check_core_tests(self.ctx)[0], verify.FAIL)
        log = (self.root / 'core-ctest.log').read_text()
        self.assertIn('100% tests passed', log)
        self.assertIn('Skipped', log)
        with mock.patch.object(build, 'BUILD_ROOT', self.root), \
                mock.patch.object(build.subprocess, 'run', return_value=subprocess.CompletedProcess([], 0, log, '')):
            with self.assertRaisesRegex(RuntimeError, '核心测试未完整通过'):
                build.test_core()


if __name__ == '__main__':
    unittest.main()
