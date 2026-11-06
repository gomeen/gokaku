#!/usr/bin/env python3
"""交付收据／发布阶段边界的离线负例；python3 -m unittest scripts.test_delivery_pipeline."""
import argparse
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
        report = {'version': delivery.current_meta(self.root), 'channel': 'dev',
                  'sourceSha256': self.source, 'profile': 'fast', 'gate': {'passed': True},
                  'checks': [{'required': True, 'status': 'passed'}],
                  'artifacts': {platform: delivery.read_json(delivery.package_receipt_path(package))['artifact']
                                for platform, package in self.packages}}
        self.report = self.root / 'report.json'
        delivery.write_json(self.report, report)

    def args(self):
        return argparse.Namespace(version=None, build=None, channel='dev', publish=False,
                                  publish_existing=None, repo='acme/releases',
                                  macos_pkg=str(self.packages[0][1]), windows_setup=str(self.packages[1][1]),
                                  verification_report=[str(self.report)], key='unused', key_id='test',
                                  notes_file=None, tag=None, require_names=True, dry_run=True,
                                  out=str(self.root / 'out'), release_state=None)

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
        (root / 'Sources').mkdir()
        (root / 'Sources/new.swift').write_text('let x = 1')
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
            with mock.patch.object(publish, 'validate_reports', side_effect=lambda p, r, c, root:
                                   delivery.validate_reports(p, r, c, root=root)):
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


if __name__ == '__main__':
    unittest.main()
