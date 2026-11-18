#!/usr/bin/env python3
"""离线路径回归：python3 -B -m unittest scripts.test_build_paths -v。

仅在临时目录 dump Swift manifest／配置无编译器 CMake 工程，不构建产品或下载依赖。
"""
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
from unittest import mock

REPO = Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location('gogaku_build', REPO / 'scripts/build.py')
build = importlib.util.module_from_spec(spec)
spec.loader.exec_module(build)
verify_spec = importlib.util.spec_from_file_location('gogaku_verify', REPO / 'scripts/verify.py')
verify = importlib.util.module_from_spec(verify_spec)
verify_spec.loader.exec_module(verify)
bundle_spec = importlib.util.spec_from_file_location('gogaku_check_bundle', REPO / 'scripts/check-bundle.py')
bundle_check = importlib.util.module_from_spec(bundle_spec)
bundle_spec.loader.exec_module(bundle_check)


class BuildPathTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='gogaku-build-paths-')
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name).resolve()

    def test_build_root_is_repo_relative_not_cwd(self):
        for value in (None, '', 'isolated build/../build', str(self.root / 'absolute build')):
            with self.subTest(value=value), mock.patch('os.getcwd', return_value='/'):
                expected = (self.root / (value or '.build')).resolve()
                self.assertEqual(build.resolve_build_root(value, root=self.root), expected)
                self.assertTrue(expected.is_absolute())

    def test_swift_command_gets_same_absolute_root_and_keeps_environment(self):
        target = self.root / 'isolated build'
        with mock.patch.object(build, 'BUILD_ROOT', target), \
                mock.patch.dict(os.environ, {'GOGAKU_BUILD_ROOT': 'wrong-relative',
                                             'GOGAKU_PATH_TEST': 'keep'}), \
                mock.patch.object(build.subprocess, 'run') as run:
            build.build_swift('debug', validation=True)
        args, kwargs = run.call_args
        # 验收构建独占 scratch 目录：SwiftPM 不跟踪 -Xswiftc -D… 变化，
        # 共用目录会把诊断代码复用进普通包（2026-11-13 实测）。
        self.assertEqual(args[0], ['swift', 'build', '-c', 'debug', '-j', '2',
                                  '--package-path', 'macos',
                                  '--scratch-path', str(target / 'swift-validation'),
                                  '-Xswiftc', '-DGOGAKU_VALIDATION'])
        self.assertEqual(kwargs['env']['GOGAKU_BUILD_ROOT'], str(target))
        self.assertEqual(kwargs['env']['GOGAKU_PATH_TEST'], 'keep')
        self.assertEqual(kwargs['cwd'], REPO)
        self.assertEqual(build.DIST, REPO / 'dist')

    def test_manifest_uses_only_selected_native_and_core_paths(self):
        package = self.root / 'repo/macos'
        package.mkdir(parents=True)
        shutil.copyfile(REPO / 'macos/Package.swift', package / 'Package.swift')
        repo = package.parent
        external = self.root / 'absolute build'
        external.mkdir()
        (repo / 'linked-build').symlink_to(external, target_is_directory=True)
        for index, value in enumerate((None, '', 'relative build/../isolated', str(external),
                                       'linked-build')):
            with self.subTest(value=value):
                env = os.environ.copy()
                env.pop('GOGAKU_BUILD_ROOT', None)
                if value is not None:
                    env['GOGAKU_BUILD_ROOT'] = value
                env['CLANG_MODULE_CACHE_PATH'] = str(self.root / 'module-cache')
                env['SWIFTPM_MODULECACHE_OVERRIDE'] = str(self.root / 'module-cache')
                result = subprocess.run(
                    ['swift', 'package', '--package-path', str(package),
                     '--scratch-path', str(self.root / f'swift-{index}'),
                     '--cache-path', str(self.root / 'swift-cache'),
                     '--manifest-cache', 'none', 'dump-package'],
                    cwd=self.root, env=env, check=True, capture_output=True, text=True)
                manifest = json.loads(result.stdout)
                selected = build.resolve_build_root(value, root=repo)
                expected = ['-L', str(selected / 'native'), '-L', str(selected / 'core'),
                            '-Xlinker', '-rpath', '-Xlinker', str(selected / 'native'),
                            '-Xlinker', '-rpath', '-Xlinker', str(selected / 'core')]
                linked = {'GogakuKit', 'GogakuInput', 'GogakuSettings', 'GogakuTranslator',
                          'GogakuKitTests'}
                for target in manifest['targets']:
                    if target['name'] in linked:
                        unsafe = [s['kind']['unsafeFlags']['_0'] for s in target['settings']
                                  if s['tool'] == 'linker' and 'unsafeFlags' in s['kind']]
                        # Foundation 会把已存在的 /private/var 简写成 /var；
                        # 比较真实目录，同时保持全部参数与路径数量的严格断言。
                        def canonical_flags(flags):
                            return [str(Path(flag).resolve()) if flag.startswith('/') else flag
                                    for flag in flags]
                        self.assertEqual([canonical_flags(flags) for flags in unsafe],
                                         [canonical_flags(expected)], target['name'])
                        linked.remove(target['name'])
                self.assertFalse(linked)

    def test_migrated_cmake_cache_is_preserved_and_reconfigured(self):
        old_source = self.root / 'native/EngineBridge'
        source = self.root / 'macos/EngineBridge'
        binary = self.root / '.build/native'
        for folder in (old_source, source):
            folder.mkdir(parents=True)
            (folder / 'CMakeLists.txt').write_text(
                'cmake_minimum_required(VERSION 3.25)\nproject(PathTest LANGUAGES NONE)\n'
                'message(STATUS "Unused test dependency: ${GOGAKU_DEPS}")\n')
        subprocess.run(['cmake', '-S', str(old_source), '-B', str(binary), '-G', 'Ninja'],
                       check=True, capture_output=True)
        old_cache = (binary / 'CMakeCache.txt').read_bytes()
        old_library = binary / 'libGogakuEngine.dylib'
        old_library.write_bytes(b'old-library-must-not-be-linked')
        first_backup = binary.with_name('native.stale-source-1')
        first_backup.mkdir()
        (first_backup / 'keep').write_text('previous backup')
        with mock.patch.object(build, 'ROOT', self.root):
            build.configure_cmake('macos/EngineBridge', binary)
        backup = binary.with_name('native.stale-source-2')
        self.assertEqual((backup / 'CMakeCache.txt').read_bytes(), old_cache)
        self.assertEqual((backup / old_library.name).read_bytes(), b'old-library-must-not-be-linked')
        self.assertEqual((first_backup / 'keep').read_text(), 'previous backup')
        self.assertFalse(old_library.exists())
        self.assertIn(f'CMAKE_HOME_DIRECTORY:INTERNAL={source}',
                      (binary / 'CMakeCache.txt').read_text())
        with mock.patch.object(build, 'ROOT', self.root):
            build.configure_cmake('macos/EngineBridge', binary)
        self.assertFalse(binary.with_name('native.stale-source-3').exists())

    def test_swift_tests_build_engine_before_running_with_repository_root(self):
        calls = []
        target = REPO / '.build'
        ctx = mock.Mock()
        ctx.__getitem__ = lambda _self, key: {'jobs': 3}[key]
        ctx.evidence.return_value = 'swift.log'

        def fake_sh(args, **kwargs):
            calls.append((args, kwargs))
            if args[:3] == ['cmake', '-S', 'macos/EngineBridge']:
                return subprocess.CompletedProcess(args, 0, 'configured', '')
            if args[:2] == ['cmake', '--build']:
                return subprocess.CompletedProcess(args, 0, 'engine built', '')
            if args[:2] == ['swift', 'test']:
                return subprocess.CompletedProcess(args, 0, 'Executed 12 tests, with 0 failures', '')
            self.fail(f'unexpected command: {args}')

        with mock.patch.dict(os.environ, {'GOGAKU_BUILD_ROOT': str(self.root / 'stale'),
                                             'GOGAKU_PATH_TEST': 'keep'}), \
                mock.patch.object(verify, 'ROOT', REPO), \
                mock.patch.object(verify, 'sh', side_effect=fake_sh):
            status, _, _ = verify.check_swift_tests(ctx)

        self.assertEqual(status, verify.PASS)
        self.assertEqual([call[0][0] for call in calls], ['cmake', 'cmake', 'swift'])
        expected = str(target.resolve())
        for args, kwargs in calls:
            self.assertEqual(kwargs['env']['GOGAKU_BUILD_ROOT'], expected)
            self.assertEqual(kwargs['env']['GOGAKU_PATH_TEST'], 'keep')
            self.assertIn('PATH', kwargs['env'])
        for args, kwargs in calls[:2]:
            self.assertIn(str(target / 'native'), [str(arg) for arg in args])
        swift_args, swift_kwargs = calls[2]
        self.assertEqual(swift_args, ['swift', 'test', '-c', 'release', '-j', '3'])
        self.assertEqual(swift_kwargs['cwd'], REPO / 'macos')

    def test_swift_engine_prepare_failure_blocks_swift_test(self):
        ctx = mock.Mock()
        ctx.__getitem__ = lambda _self, key: {'jobs': 2}[key]
        ctx.evidence.return_value = 'engine.log'
        calls = []

        def fake_sh(args, **kwargs):
            calls.append(args)
            return subprocess.CompletedProcess(args, 1, '', 'engine failure')

        with mock.patch.object(verify, 'sh', side_effect=fake_sh):
            status, detail, _ = verify.check_swift_tests(ctx)
        self.assertEqual(status, verify.FAIL)
        self.assertIn('引擎配置失败', detail)
        self.assertEqual(len(calls), 1)
        self.assertEqual(calls[0][:3], ['cmake', '-S', 'macos/EngineBridge'])

    def test_swift_engine_build_failure_blocks_swift_test(self):
        ctx = mock.Mock()
        ctx.__getitem__ = lambda _self, key: {'jobs': 2}[key]
        ctx.evidence.return_value = 'engine.log'
        calls = []

        def fake_sh(args, **kwargs):
            calls.append(args)
            code = 0 if args[0] == 'cmake' and '--build' not in args else 1
            return subprocess.CompletedProcess(args, code, '', 'engine failure')

        with mock.patch.object(verify, 'sh', side_effect=fake_sh):
            status, detail, _ = verify.check_swift_tests(ctx)
        self.assertEqual(status, verify.FAIL)
        self.assertIn('引擎构建失败', detail)
        self.assertEqual(len(calls), 2)
        self.assertNotIn('swift', [args[0] for args in calls])

    def test_render_show_bin_path_uses_repository_build_root(self):
        ctx = {'core_dir': self.root / 'core'}
        with mock.patch.dict(os.environ, {'GOGAKU_BUILD_ROOT': str(self.root / 'stale'),
                                             'GOGAKU_PATH_TEST': 'keep'}), \
                mock.patch.object(verify, 'ROOT', REPO), \
                mock.patch.object(verify, 'sh') as sh:
            sh.return_value = subprocess.CompletedProcess([], 1, '', 'stop after path query')
            verify.check_render(ctx)
        args, kwargs = sh.call_args
        self.assertEqual(args[0], ['swift', 'build', '-c', 'release', '--show-bin-path'])
        self.assertEqual(kwargs['env']['GOGAKU_BUILD_ROOT'], str((REPO / '.build').resolve()))
        self.assertEqual(kwargs['env']['GOGAKU_PATH_TEST'], 'keep')
        self.assertIn('PATH', kwargs['env'])

    def test_bundle_marker_scan_strips_debug_symbols_and_preserves_original(self):
        source_root = Path(tempfile.mkdtemp(prefix='gogaku-debug-', dir='/tmp'))
        self.addCleanup(shutil.rmtree, source_root)
        binary = self.root / 'debug-path-fixture'
        source = source_root / 'fixture.c'
        source.write_text('int main(void) { return 0; }\n')
        subprocess.run(['clang', '-g', str(source), '-o', str(binary)], check=True, capture_output=True)
        self.assertIn(b'/tmp/gogaku-', binary.read_bytes())
        original_hash = __import__('hashlib').sha256(binary.read_bytes()).hexdigest()
        bundle_check.assert_no_forbidden_runtime_strings(binary,
                                                         (b'/tmp/gogaku-', b'gogaku-keys.log', b'gogaku-debug-enabled'))
        self.assertEqual(__import__('hashlib').sha256(binary.read_bytes()).hexdigest(), original_hash)

    def test_bundle_marker_scan_rejects_each_runtime_forbidden_string(self):
        forbidden = (b'/tmp/gogaku-', b'gogaku-keys.log', b'gogaku-debug-enabled')
        for index, marker in enumerate(forbidden):
            with self.subTest(marker=marker):
                binary = self.root / f'runtime-marker-{index}'
                source = self.root / f'runtime-marker-{index}.c'
                source.write_text(f'const char marker[] = "{marker.decode()}"; int main(void) {{ return marker[0] == 0; }}\n')
                subprocess.run(['clang', '-g', str(source), '-o', str(binary)], check=True, capture_output=True)
                original_hash = __import__('hashlib').sha256(binary.read_bytes()).hexdigest()
                with self.assertRaises(AssertionError):
                    bundle_check.assert_no_forbidden_runtime_strings(binary, forbidden)
                self.assertEqual(__import__('hashlib').sha256(binary.read_bytes()).hexdigest(), original_hash)
        binary = self.root / 'strip-failure-fixture'
        binary.write_bytes(b'original executable bytes')
        original_hash = __import__('hashlib').sha256(binary.read_bytes()).hexdigest()
        with mock.patch.object(bundle_check.subprocess, 'run',
                               return_value=subprocess.CompletedProcess([], 1, '', 'strip failed')):
            with self.assertRaises(AssertionError):
                bundle_check.assert_no_forbidden_runtime_strings(binary, (b'/tmp/gogaku-',))
        self.assertEqual(__import__('hashlib').sha256(binary.read_bytes()).hexdigest(), original_hash)


if __name__ == '__main__':
    unittest.main()
