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
        self.assertEqual(args[0], ['swift', 'build', '-c', 'debug', '-j', '2',
                                  '--package-path', 'macos', '--scratch-path', str(target / 'swift'),
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

    def test_cmake_cache_with_current_source_is_reused(self):
        binary = self.root / 'core'
        binary.mkdir()
        cache = binary / 'CMakeCache.txt'
        source = REPO / 'shared/GogakuCore'
        cache.write_text(f'CMAKE_HOME_DIRECTORY:INTERNAL={source}\n')
        with mock.patch.object(build, 'run') as run:
            build.configure_cmake('shared/GogakuCore', binary)
        self.assertTrue(cache.is_file())
        self.assertEqual(run.call_args.args[0][:5], ['cmake', '-S', source, '-B', binary])


if __name__ == '__main__':
    unittest.main()
