#!/usr/bin/env python3
"""交付收据／发布阶段边界的离线负例；python3 -m unittest scripts.test_delivery_pipeline."""
import argparse
import copy
import hashlib
import importlib.util
import json
from pathlib import Path
import sys
import subprocess
import tempfile
import unittest
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parent))
import _gogaku_delivery as delivery
import _gogaku_verification as verification
spec = importlib.util.spec_from_file_location('publish_release', Path(__file__).with_name('publish-release.py'))
publish = importlib.util.module_from_spec(spec)
spec.loader.exec_module(publish)


class DeliveryPipelineTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        (self.root / 'version.json').write_text('{"version":"0.1.0-dev.1","buildNumber":12}')
        (self.root / 'resources/update').mkdir(parents=True)
        (self.root / 'resources/update/config.json').write_text(json.dumps({
            'owner': 'acme', 'repo': 'releases',
            'trustedKeys': [{'keyId': 'test', 'publicKey': 'A' * 42 + 'A='}]}))
        self.source = delivery.source_fingerprint(self.root)
        self.git = {'commit': 'a' * 40, 'dirty': True}
        self.packages = []
        for platform, extension in [('macos', 'pkg'), ('windows', 'exe')]:
            name = ('Gogaku-0.1.0-dev.1-b12-dev.pkg' if platform == 'macos' else
                    'Gogaku-0.1.0-dev.1-b12-dev-windows-x64-setup.exe')
            package = self.root / name
            package.write_bytes((platform + ' package').encode())
            receipt = {'schema': 1, 'kind': 'installer', 'platform': platform, 'arch': 'x86_64',
                       'channel': 'dev', 'fullVersion': '0.1.0-dev.1', 'buildNumber': 12,
                       'sourceSha256': self.source, 'git': self.git, 'configuration': 'release',
                       'validationBuild': False, 'inputIdentitySha256': 'a' * 64,
                       'licenseFiles': ['licenses/third-party.md'],
                       'artifact': {'name': name, 'sha256': delivery.sha256(package),
                                    'bytes': package.stat().st_size}}
            delivery.write_json(delivery.package_receipt_path(package), receipt)
            self.packages.append((platform, package))
        self.report = self.root / 'report.json'
        delivery.write_json(self.report, self.make_report())

    def receipts(self):
        return [delivery.read_json(delivery.package_receipt_path(package))
                for _, package in self.packages]

    def make_report(self, profile='fast'):
        checks = [{'name': name, 'required': required, 'status': 'passed'}
                  for name, required in verification.PROFILE_CHECKS[profile]]
        return {'version': delivery.current_meta(self.root), 'channel': 'dev',
                'sourceSha256': delivery.source_fingerprint(self.root),
                'testSha256': delivery.test_fingerprint(self.root),
                'platformFingerprints': delivery.platform_fingerprints(self.root),
                'policyVersion': verification.POLICY_VERSION, 'runIdentityStable': True,
                'commit': self.git['commit'], 'dirty': self.git['dirty'], 'quick': False,
                'profile': profile, 'gate': verification.validate_checks(profile, checks),
                'checks': checks, 'summary': verification.summarize_checks(checks),
                'artifacts': {r['platform']: r['artifact'] for r in self.receipts()}}

    def validate_report(self, report):
        delivery.write_json(self.report, report)
        delivery.validate_reports([self.report], self.receipts(), 'dev', root=self.root)

    def put(self, relative, content='input'):
        path = self.root / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(content)
        return path

    def args(self):
        return argparse.Namespace(version=None, build=None, channel='dev', publish=False,
                                  publish_existing=None, repo='acme/releases',
                                  macos_pkg=str(self.packages[0][1]), windows_setup=str(self.packages[1][1]),
                                  verification_report=[str(self.report)], key='unused', key_id='test',
                                  notes_file=None, waive_host=None, tag=None, require_names=True, dry_run=True,
                                  out=str(self.root / 'out'), release_state=None)

    def test_fingerprints_prune_generated_cache_subtrees(self):
        self.put('macos/Sources/Input.swift', 'let x = 1')
        self.put('probes/input.json', '{"case":1}')
        before = (delivery.source_fingerprint(self.root), delivery.test_fingerprint(self.root))
        for base in ('macos', 'scripts', 'probes', 'shared/GogakuCore/tests'):
            for cache in delivery.GENERATED_DIRS:
                self.put(f'{base}/{cache}/nested/cache', 'generated')
            self.put(f'{base}/.DS_Store')
            self.put(f'{base}/loose.pyc')
        self.put('probes/results/evidence.json')
        self.put('docs/validation/verify/report.json')
        with mock.patch.object(delivery, 'sha256', wraps=delivery.sha256) as digest:
            self.assertEqual(before, (delivery.source_fingerprint(self.root), delivery.test_fingerprint(self.root)))
        self.assertFalse(any('cache' == Path(call.args[0]).name for call in digest.call_args_list))
        # 文件过滤不够：检查 os.walk 真正访问的目录，不得进入生成子树。
        visited = []
        walk = delivery.os.walk
        def observing_walk(path):
            for folder, dirs, files in walk(path):
                visited.append(Path(folder).relative_to(self.root).parts)
                yield folder, dirs, files
        with mock.patch.object(delivery.os, 'walk', side_effect=observing_walk):
            delivery.source_fingerprint(self.root)
            delivery.test_fingerprint(self.root)
        self.assertFalse(any(set(parts) & delivery.GENERATED_DIRS for parts in visited))
        self.assertFalse(any('results' in parts for parts in visited))

    def test_real_source_changes_source_identity(self):
        path = self.put('macos/Sources/Input.swift', 'let x = 1')
        source = delivery.source_fingerprint(self.root)
        tests = delivery.test_fingerprint(self.root)
        path.write_text('let x = 2')
        self.assertNotEqual(source, delivery.source_fingerprint(self.root))
        self.assertEqual(tests, delivery.test_fingerprint(self.root))
        path.unlink()
        self.assertNotEqual(source, delivery.source_fingerprint(self.root))

    def test_test_implementation_and_frozen_cases_bind_independently(self):
        for relative in ('scripts/test_check.py', 'probes/cases.json',
                         'macos/Tests/Case.swift', 'shared/GogakuCore/tests/case.cpp',
                         'validation/frozen.json', '.github/workflows/windows.yml'):
            with self.subTest(relative=relative):
                before = delivery.test_fingerprint(self.root)
                path = self.put(relative, 'case one')
                self.assertNotEqual(before, delivery.test_fingerprint(self.root))
                before = delivery.test_fingerprint(self.root)
                path.write_text('case two')
                self.assertNotEqual(before, delivery.test_fingerprint(self.root))
                path.unlink()
                self.assertNotEqual(before, delivery.test_fingerprint(self.root))

    def test_probe_change_invalidates_report_not_package(self):
        self.put('probes/cases.json', 'new test input')
        self.assertEqual(self.source, delivery.source_fingerprint(self.root))
        for platform, package in self.packages:
            delivery.validate_package(package, platform, 'dev', root=self.root)
        with self.assertRaisesRegex(delivery.DeliveryError, '测试身份'):
            delivery.validate_reports([self.report], self.receipts(), 'dev', root=self.root)
        report = self.make_report()
        # 测试专属变更提交后，产物源码身份仍有效；报告用新测试身份重新验证。
        report['commit'] = 'b' * 40
        self.validate_report(report)

    def test_report_rejects_policy_tampering(self):
        base = self.make_report()
        mutations = {
            'missing check': lambda r: r['checks'].pop(),
            'fake required': lambda r: r['checks'][0].update(required=False),
            'duplicate check': lambda r: r['checks'].append(dict(r['checks'][0])),
            'unknown check': lambda r: r['checks'][0].update(name='unlisted-check'),
            'unknown profile': lambda r: r.update(profile='unknown'),
            'old policy': lambda r: r.update(policyVersion=1),
            'missing policy': lambda r: r.pop('policyVersion'),
            'old tests': lambda r: r.update(testSha256='0' * 64),
            'missing tests': lambda r: r.pop('testSha256'),
            'unstable run': lambda r: r.update(runIdentityStable=False),
            'missing stability': lambda r: r.pop('runIdentityStable'),
            'failed required': lambda r: r['checks'][0].update(status='failed'),
            'skipped required': lambda r: r['checks'][0].update(status='skipped'),
            'blocked required': lambda r: r['checks'][0].update(status='blocked'),
            'unknown status': lambda r: r['checks'][0].update(status='ok'),
            'false gate': lambda r: r['gate'].update(passed=False),
            'fake notPassed': lambda r: r['gate'].update(notPassed=['version']),
            'wrong summary': lambda r: r['summary'].update(passed=99),
            'invalid commit': lambda r: r.update(commit='not-git'),
        }
        for label, mutate in mutations.items():
            with self.subTest(label=label):
                report = copy.deepcopy(base)
                mutate(report)
                with self.assertRaises(delivery.DeliveryError):
                    self.validate_report(report)

    def test_report_rejects_bad_types_without_crashing(self):
        base = self.make_report()
        bad_values = {'checks': [None, {}, 'passed', [None], [1]],
                      'profile': [None, [], {}], 'gate': [None, [], True, {'passed': 1, 'notPassed': []}],
                      'version': [None, [], {'version': '0.1.0-dev.1', 'buildNumber': True}],
                      'policyVersion': [None, '2', True], 'runIdentityStable': [None, 1, 'true'],
                      'quick': [None, 0, 'false'], 'dirty': [None, 1], 'commit': [None, [], ''],
                      'sourceSha256': [None, []], 'testSha256': [None, {}],
                      'artifacts': [None, [], {}], 'summary': [None, [], {'passed': True}]}
        for field, values in bad_values.items():
            for value in values:
                with self.subTest(field=field, value=value):
                    report = copy.deepcopy(base)
                    report[field] = value
                    with self.assertRaises(delivery.DeliveryError):
                        self.validate_report(report)
        for field, value in [('required', 1), ('name', []), ('status', {}),
                             ('durationMs', True), ('durationMs', -1), ('detail', []), ('evidence', {})]:
            with self.subTest(check_field=field):
                report = copy.deepcopy(base)
                report['checks'][0][field] = value
                with self.assertRaises(delivery.DeliveryError):
                    self.validate_report(report)
        for report in (None, [], 'not an object', 3):
            with self.assertRaises(delivery.DeliveryError):
                self.validate_report(report)

    def test_optional_blocked_does_not_fail_gate(self):
        release = self.root / 'release.json'
        paths = [self.report, release]
        for status in verification.STATUSES:
            report = self.make_report('release')
            optional = next(c for c in report['checks'] if not c['required'])
            optional['status'] = status
            report['summary'] = verification.summarize_checks(report['checks'])
            delivery.write_json(release, report)
            delivery.validate_reports(paths, self.receipts(), 'dev', root=self.root)
        report['checks'].remove(optional)
        delivery.write_json(release, report)
        with self.assertRaises(delivery.DeliveryError):
            delivery.validate_reports(paths, self.receipts(), 'dev', root=self.root)

    def make_final(self, version='0.1.0', build=12):
        self.put('version.json', json.dumps({'version': version, 'buildNumber': build}))
        self.git['dirty'] = False
        for platform, package in self.packages:
            receipt = delivery.read_json(delivery.package_receipt_path(package))
            receipt.update(fullVersion=version, buildNumber=build,
                           sourceSha256=delivery.source_fingerprint(self.root), git=dict(self.git))
            delivery.write_json(delivery.package_receipt_path(package), receipt)

    def write_reports(self, profiles):
        paths = []
        for profile in profiles:
            path = self.root / f'{profile}.json'
            delivery.write_json(path, self.make_report(profile))
            paths.append(path)
        return paths

    def test_rc_version_is_no_longer_accepted(self):
        self.put('version.json', json.dumps({'version': '0.1.0-rc.1', 'buildNumber': 12}))
        with self.assertRaisesRegex(delivery.DeliveryError, 'rc'):
            delivery.current_meta(self.root)

    def test_final_requires_fast_release_and_one_host_tier_clean_and_full(self):
        self.make_final()
        for host in verification.HOST_PROFILES:
            with self.subTest(host=host):
                paths = self.write_reports(('fast', 'release', host))
                receipts = self.receipts()
                delivery.validate_reports(paths, receipts, 'dev', root=self.root)
                for missing in range(3):
                    with self.assertRaisesRegex(delivery.DeliveryError, '缺少必需'):
                        delivery.validate_reports(paths[:missing] + paths[missing + 1:], receipts, 'dev', root=self.root)
                for path in paths:
                    for field in ('quick', 'dirty', 'runIdentityStable'):
                        original = delivery.read_json(path)
                        changed = copy.deepcopy(original)
                        changed[field] = field != 'runIdentityStable'
                        delivery.write_json(path, changed)
                        with self.assertRaises(delivery.DeliveryError):
                            delivery.validate_reports(paths, receipts, 'dev', root=self.root)
                        delivery.write_json(path, original)
        both = self.write_reports(('fast', 'release', 'host', 'host-full'))
        with self.assertRaisesRegex(delivery.DeliveryError, '重复'):
            delivery.validate_reports(both, self.receipts(), 'dev', root=self.root)

    def test_host_waiver_only_skips_host_with_written_reason(self):
        self.make_final()
        paths = self.write_reports(('fast', 'release'))
        with self.assertRaisesRegex(delivery.DeliveryError, 'host'):
            delivery.validate_reports(paths, self.receipts(), 'dev', root=self.root)
        for reason in (None, '', '  '):
            with self.assertRaises(delivery.DeliveryError):
                delivery.validate_reports(paths, self.receipts(), 'dev', root=self.root, waive_host=reason)
        delivery.validate_reports(paths, self.receipts(), 'dev', root=self.root, waive_host='用户决定')
        with self.assertRaisesRegex(delivery.DeliveryError, 'release'):
            delivery.validate_reports(paths[:1], self.receipts(), 'dev', root=self.root, waive_host='用户决定')

    def test_heavy_reports_carry_over_windows_only_change_and_build_bump(self):
        self.make_final(build=12)
        paths = self.write_reports(('fast', 'release', 'host'))
        # 只改 Windows＋只递增构建号：release／host 沿用，fast 必须重跑。
        self.put('windows/GogakuWindows/tsf.cpp', 'fix')
        self.put('probes/windows-field-safety.cpp', 'fix')
        self.put('scripts/compile-win-native.py', 'fix')
        self.make_final(build=13)
        with self.assertRaisesRegex(delivery.DeliveryError, '身份'):
            delivery.validate_reports(paths, self.receipts(), 'dev', root=self.root)
        fast = self.write_reports(('fast',))[0]
        delivery.validate_reports([fast, paths[1], paths[2]], self.receipts(), 'dev', root=self.root)
        # Mac 侧或共享核心改动：沿用失效。
        for relative in ('macos/Sources/Input.swift', 'shared/GogakuCore/src/core.cpp',
                         'probes/validate-real-hosts.py', 'scripts/verify.py'):
            with self.subTest(relative=relative):
                path = self.put(relative, 'mac change')
                fast = self.write_reports(('fast',))[0]
                with self.assertRaisesRegex(delivery.DeliveryError, 'Mac'):
                    delivery.validate_reports([fast, paths[1], paths[2]], self.receipts(), 'dev', root=self.root)
                path.unlink()
        # 版本字符串改变或报告构建号高于当前：拒绝沿用。
        self.make_final(version='0.1.1', build=14)
        fast = self.write_reports(('fast',))[0]
        with self.assertRaisesRegex(delivery.DeliveryError, '版本不同'):
            delivery.validate_reports([fast, paths[1], paths[2]], self.receipts(), 'dev', root=self.root)

    def test_release_tooling_changes_tests_not_packages(self):
        source, tests = delivery.source_fingerprint(self.root), delivery.test_fingerprint(self.root)
        mac = delivery.platform_fingerprints(self.root)['macos']
        self.put('scripts/verify.py', 'changed gate')
        self.assertEqual(source, delivery.source_fingerprint(self.root))
        self.assertNotEqual(tests, delivery.test_fingerprint(self.root))
        now = delivery.platform_fingerprints(self.root)['macos']
        self.assertEqual(mac['sourceSha256'], now['sourceSha256'])
        self.assertNotEqual(mac['testSha256'], now['testSha256'])
        self.put('scripts/build.py', 'changed build')
        self.assertNotEqual(source, delivery.source_fingerprint(self.root))

    def test_platform_fingerprints_split_by_owner(self):
        before = delivery.platform_fingerprints(self.root)
        self.put('windows/a.cpp')
        after = delivery.platform_fingerprints(self.root)
        self.assertEqual(before['macos'], after['macos'])
        self.assertNotEqual(before['windows'], after['windows'])
        self.put('macos/Sources/a.swift')
        later = delivery.platform_fingerprints(self.root)
        self.assertEqual(after['windows'], later['windows'])
        self.assertNotEqual(after['macos'], later['macos'])
        self.put('shared/GogakuCore/a.cpp')
        shared = delivery.platform_fingerprints(self.root)
        self.assertTrue(all(shared[p] != later[p] for p in delivery.PLATFORMS))
        self.put('version.json', '{"version":"0.1.0-dev.1","buildNumber":99}')
        self.assertEqual(shared, delivery.platform_fingerprints(self.root))

    def test_duplicate_profiles_and_missing_installer_rejected(self):
        with self.assertRaises(delivery.DeliveryError):
            delivery.validate_reports([self.report, self.report], self.receipts(), 'dev', root=self.root)
        with self.assertRaises(delivery.DeliveryError):
            delivery.validate_reports([self.report], self.receipts()[:1], 'dev', root=self.root)

    def test_untracked_source_marks_clean_build_dirty(self):
        root = self.root
        subprocess.run(['git', 'init', '-q', root], check=True)
        subprocess.run(['git', '-C', str(root), 'add', 'version.json'], check=True)
        subprocess.run(['git', '-C', str(root), '-c', 'user.name=Test', '-c', 'user.email=test@example.com',
                        'commit', '-qm', 'init'], check=True)
        (root / 'docs/validation').mkdir(parents=True)
        (root / 'docs/validation/untracked-report.json').write_text('{}')
        self.assertTrue(delivery.working_tree_dirty(root), '未跟踪的 update config 是构建输入')
        # 先把 fixture 中源码输入纳入提交，再仅创建未跟踪的验证报告。
        subprocess.run(['git', '-C', str(root), 'add', 'resources'], check=True)
        subprocess.run(['git', '-C', str(root), '-c', 'user.name=Test', '-c', 'user.email=test@example.com',
                        'commit', '-qm', 'config'], check=True)
        self.assertFalse(delivery.working_tree_dirty(root), '验证报告不影响构建身份')
        (root / 'macos/Sources').mkdir(parents=True)
        (root / 'macos/Sources/new.swift').write_text('let x = 1')
        self.assertTrue(delivery.working_tree_dirty(root), '未跟踪源码必须阻止干净发布')

    def test_old_package_renamed_fails_receipt(self):
        platform, package = self.packages[0]
        package.write_bytes(b'old package under current name')
        with self.assertRaisesRegex(delivery.DeliveryError, '收据不符'):
            delivery.validate_package(package, platform, 'dev', root=self.root)

    def test_cross_channel_and_old_compilation_fail(self):
        platform, package = self.packages[0]
        receipt_path = delivery.package_receipt_path(package)
        receipt = delivery.read_json(receipt_path)
        receipt['channel'] = 'stable'
        delivery.write_json(receipt_path, receipt)
        with self.assertRaisesRegex(delivery.DeliveryError, '通道不符'):
            delivery.validate_package(package, platform, 'dev', root=self.root)
        folder = self.root / 'bin/x86'
        folder.mkdir(parents=True)
        binary = folder / 'GogakuTsf.dll'
        binary.write_bytes(b'dev binary')
        receipt = dict(schema=1, fullVersion='0.1.0-dev.1', buildNumber=12, channel='stable',
                       sourceSha256=self.source, git=self.git, arch='x86', configuration='release',
                       artifacts={'GogakuTsf.dll': {'sha256': delivery.sha256(binary),
                                                     'bytes': binary.stat().st_size}})
        path = folder / 'build-receipt.json'
        delivery.write_json(path, receipt)
        with self.assertRaisesRegex(delivery.DeliveryError, '通道不符'):
            delivery.validate_compile_receipt(path, folder, 'dev', 'x86', root=self.root)

    def test_report_must_bind_both_installers(self):
        receipts = [delivery.validate_package(p, platform, 'dev', root=self.root)
                    for platform, p in self.packages]
        delivery.validate_reports([self.report], receipts, 'dev', root=self.root)
        report = delivery.read_json(self.report)
        report['artifacts']['windows']['sha256'] = '0' * 64
        delivery.write_json(self.report, report)
        with self.assertRaisesRegex(delivery.DeliveryError, '哈希'):
            delivery.validate_reports([self.report], receipts, 'dev', root=self.root)

    def test_publisher_dry_run_rejects_renamed_old_and_fake_bytes(self):
        args = self.args()
        with mock.patch.object(publish, 'ROOT', self.root):
            with mock.patch.object(publish, 'validate_reports', side_effect=lambda p, r, c, root, waive_host=None:
                                   delivery.validate_reports(p, r, c, root=root, waive_host=waive_host)):
                publish.validate(args)
                self.packages[0][1].write_bytes(b'not a pkg')
                with self.assertRaisesRegex(delivery.DeliveryError, '收据不符'):
                    publish.validate(args)

    def test_remote_draft_id_and_assets_must_match(self):
        args = self.args()
        args.publish_existing = 71
        args.dry_run = False
        meta = {'tag': 'v0.1.0-dev.1-b12-dev', 'name': 'Gogaku 0.1.0-dev.1（构建 12）'}
        records = {}
        for index, (_, path) in enumerate(self.packages):
            records[path.name] = {'id': index + 1, 'name': path.name,
                                  'bytes': path.stat().st_size, 'sha256': delivery.sha256(path)}
        for index, name in enumerate(('update-manifest.json', 'update-manifest.json.sig'), 3):
            path = self.root / name
            path.write_bytes(name.encode())
            records[name] = {'id': index, 'name': name,
                             'bytes': path.stat().st_size, 'sha256': delivery.sha256(path)}
        state = {'tag': meta['tag'], 'assets': records}
        url = 'https://api.github.com/repos/acme/releases/releases/71'
        release = {'id': 71, 'url': url, 'draft': True, 'prerelease': True,
                   'tag_name': meta['tag'], 'name': meta['name']}
        assets = [{'id': item['id'], 'name': item['name'], 'size': item['bytes'],
                   'state': 'uploaded', 'digest': 'sha256:' + item['sha256']}
                  for item in records.values()]
        def api(method, endpoint, token, payload=None):
            self.assertEqual(method, 'GET')
            return release if endpoint == url else assets
        with mock.patch.object(publish, 'api_request', side_effect=api):
            publish.validate_remote(args, meta, state, 'fake')
            assets[0]['digest'] = 'sha256:' + '0' * 64
            with self.assertRaises(SystemExit):
                publish.validate_remote(args, meta, state, 'fake')
            assets[0]['digest'] = 'sha256:' + list(records.values())[0]['sha256']
            release['id'] = 72
            with self.assertRaises(SystemExit):
                publish.validate_remote(args, meta, state, 'fake')

    def test_publish_existing_only_patches_original_release(self):
        args = self.args()
        args.publish_existing = 71
        args.dry_run = False
        args.key = ''
        records = {path.name: {'id': i + 1, 'name': path.name, 'bytes': path.stat().st_size,
                               'sha256': delivery.sha256(path)}
                   for i, (_, path) in enumerate(self.packages)}
        meta = {'tag': 'v0.1.0-dev.1-b12-dev', 'version': '0.1.0-dev.1', 'build': 12,
                'channel': 'dev', 'name': 'Gogaku 0.1.0-dev.1（构建 12）'}
        state = {'tag': meta['tag'], 'assets': records}
        calls = []
        def api(method, url, token, payload=None):
            calls.append((method, url))
            if method == 'PATCH':
                return {'id': 71, 'draft': False}
            raise AssertionError('第二阶段不允许再次 POST 或下载到未经核对的 ID')
        with mock.patch.object(publish, 'validate', return_value=meta), \
             mock.patch.object(publish, 'validate_state', return_value=state), \
             mock.patch.object(publish, 'validate_remote', return_value=None), \
             mock.patch.object(publish, 'api_request', side_effect=api), \
             mock.patch.dict('os.environ', {'GITHUB_TOKEN': 'fake'}):
            publish.publish(args)
        self.assertEqual(calls, [('PATCH', 'https://api.github.com/repos/acme/releases/releases/71')])


class VerificationPolicyTests(unittest.TestCase):
    def test_policy_names_and_requirements(self):
        self.assertEqual(verification.POLICY_VERSION, 3)
        self.assertEqual(verification.PROFILE_CHECKS['fast'], tuple((name, True) for name in (
            'version', 'resources', 'core-tests', 'swift-tests', 'translation-data',
            'verification-contracts', 'delivery-contracts')))
        self.assertEqual(verification.PROFILE_CHECKS['release'], tuple((name, name != 'install-preflight') for name in (
            'version', 'resources', 'core-tests', 'swift-tests', 'translation-data',
            'verification-contracts', 'clean-build', 'bundle-check', 'quality', 'render',
            'data-reliability', 'delivery-contracts', 'asan-ubsan', 'install-preflight')))
        self.assertEqual(verification.PROFILE_CHECKS['host'], tuple((name, True) for name in (
            'host-plan', 'host-identity', 'host-matrix-round-1', 'performance', 'native-gui')))
        self.assertEqual(verification.PROFILE_CHECKS['host-full'], tuple((name, True) for name in (
            'host-plan', 'host-identity', 'host-matrix-round-1', 'host-matrix-round-2',
            'orca-shift', 'performance', 'stability', 'native-gui')))


class CTestResultTests(unittest.TestCase):
    OUTPUT = ('Internal ctest changing into directory: /tmp/core\n'
              'Test project /tmp/core\n'
              '    Start 1: first\n'
              '1/2 Test #1: first ................ Passed    0.01 sec\n'
              '    Start 2: second\n'
              '2/2 Test #2: second ............... Passed    0.02 sec\n'
              '100% tests passed, 0 tests failed out of 2\n'
              'Total Test time (real) = 0.03 sec\n')

    def test_positive_complete_ctest(self):
        self.assertEqual(verification.validate_ctest_result(0, self.OUTPUT), [])
        self.assertEqual(verification.validate_ctest_result(0, self.OUTPUT.replace('\n', '\r\n')), [])
        current_ctest = self.OUTPUT.replace(', 0 tests failed', '')
        self.assertEqual(verification.validate_ctest_result(0, current_ctest), [])

    def test_rejects_failure_skips_zero_and_fake_summaries(self):
        cases = [
            (1, self.OUTPUT, ''),
            (0, '', ''),
            (0, '100% tests passed', ''),
            (0, '100% tests passed, 0 tests failed out of 0\n', ''),
            (0, '100% tests passed, 0 tests failed out of 2\n', ''),
            (0, 'No tests were found!!!\n', ''),
            (0, self.OUTPUT, 'No tests were found!!!'),
            (0, self.OUTPUT.replace('Passed', '***Skipped', 1), ''),
            (0, self.OUTPUT.replace('Passed', '***Not Run', 1), ''),
            (0, self.OUTPUT, 'SKIP: missing test data'),
            (0, self.OUTPUT + '1 test skipped\n', ''),
            (0, self.OUTPUT + 'The following tests did not run:\n', ''),
            (0, self.OUTPUT, 'second (Disabled)'),
            (0, self.OUTPUT.replace('100%', '50%'), ''),
            (0, self.OUTPUT.replace('0 tests failed', '1 tests failed'), ''),
            (0, self.OUTPUT.replace('out of 2', 'out of 3'), ''),
            (0, self.OUTPUT.replace('2/2 Test #2', '1/2 Test #1'), ''),
            (0, self.OUTPUT.replace('2/2', '2/3'), ''),
            (0, self.OUTPUT + '100% tests passed, 0 tests failed out of 2\n', ''),
            (True, self.OUTPUT, ''), (0, None, ''),
        ]
        for code, stdout, stderr in cases:
            with self.subTest(code=code, stdout=stdout, stderr=stderr):
                self.assertTrue(verification.validate_ctest_result(code, None if stdout is None else stdout + '\n' + stderr))


if __name__ == '__main__':
    unittest.main()
