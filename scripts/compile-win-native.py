#!/usr/bin/env python3
"""在 macOS/Linux 以 MinGW-w64 编译 Windows 组件，不执行任何 Windows 程序。

依赖为 prepare-win-cross.sh / build-win-selfcheck-exe.sh 已准备的静态 libime。
用 --arch x64 先构建代理、设置与核心，再用 --arch x86 构建 32 位 TSF。
最终安装器由 build-win-app.py 调用 Inno Setup 编译。
"""
from __future__ import annotations
import argparse
from concurrent.futures import ThreadPoolExecutor
import json
from pathlib import Path
import shutil
import subprocess
import sys

ROOT = Path(__file__).resolve().parent.parent
from _gogaku_delivery import (DeliveryError, git_identity, sha256, source_fingerprint,
                              validate_compile_receipt, write_json)


def run(command):
    subprocess.run([str(item) for item in command], cwd=ROOT, check=True)


def build_panel_renderer(args, arch, prefix):
    """同源静态渲染器按宿主架构编译；x86 不依赖 x64 输入核心或 libime。"""
    build = args.out / ('panel-' + arch)
    run(['cmake', '-S', ROOT / 'shared/GogakuCore/panel_render', '-B', build, '-G', 'Ninja',
         '-DCMAKE_SYSTEM_NAME=Windows',
         '-DCMAKE_SYSTEM_PROCESSOR=' + ('AMD64' if arch == 'x64' else 'x86'),
         '-DCMAKE_C_COMPILER=' + shutil.which(prefix + '-gcc'),
         '-DCMAKE_CXX_COMPILER=' + shutil.which(prefix + '-g++'),
         '-DCMAKE_RC_COMPILER=' + shutil.which(prefix + '-windres'),
         '-DCMAKE_BUILD_TYPE=Release', '-DGOGAKU_PANEL_EXPORTS=OFF'])
    run(['cmake', '--build', build, '--target', 'GogakuPanelRender', '-j', args.jobs])
    return [build / ('lib' + name + '.a') for name in
            ('GogakuPanelRender', 'gogaku_harfbuzz', 'gogaku_freetype', 'gogaku_png', 'gogaku_zlib')]


def compile_arch(args, arch):
    prefix = 'x86_64-w64-mingw32' if arch == 'x64' else 'i686-w64-mingw32'
    cxx, cc, windres = prefix + '-g++', prefix + '-gcc', prefix + '-windres'
    for tool in (cxx, cc, windres):
        if not shutil.which(tool):
            raise SystemExit(f'缺少交叉编译器：{tool}')
    panel_libs = build_panel_renderer(args, arch, prefix)
    out = args.out / 'bin' / arch
    obj = args.out / ('obj64' if arch == 'x64' else 'obj32')
    out.mkdir(parents=True, exist_ok=True)
    obj.mkdir(parents=True, exist_ok=True)
    flags = ['-std=c++20', '-O2', '-DNDEBUG', '-DNOMINMAX', '-D_WIN32_WINNT=0x0A00',
             '-DUNICODE', '-D_UNICODE', '-fmax-errors=3', '-fdiagnostics-plain-output',
             '-DGOGAKU_SETTINGS_CONTRACT_STATIC',
             f'-DGOGAKU_CHANNEL="{args.channel}"']
    if args.channel == 'dev':
        flags.append('-DGOGAKU_DEV')
    if getattr(args, 'flavor', 'full') == 'lite':
        flags.append('-DGOGAKU_LITE')
    windows = ROOT / 'windows/GogakuWindows'
    tsf = ROOT / 'windows/GogakuTsf'
    common = ['platform', 'appearance', 'themes']
    service = ['dllmain', 'text_service', 'candidate_window', 'core_bridge']
    # enable 是用户级启用（HKCU 输入法列表）的唯一实现：安装器静默调用、设置页
    # 按钮和自检程序共用，不另写第二份「拼条目串／查列表」逻辑。
    sources = [(windows / f'{name}.cpp', obj / f'{name}.o') for name in common + ['enable']]
    sources += [(ROOT / 'shared/GogakuCore/settings_contract.cpp', obj / 'settings_contract.o')]
    sources += [(ROOT / 'shared/GogakuCore/theme_contract.cpp', obj / 'theme_contract.o')]
    sources += [(tsf / 'src' / f'{name}.cpp', obj / f'{name}.o') for name in service]
    if arch == 'x64':
        sources += [(windows / f'{name}.cpp', obj / f'{name}.o')
                    for name in ('agent', 'services', 'update', 'settings')]

    def compile_one(pair):
        source, target = pair
        # Include changes must invalidate every object; always compile source.
        print(f'编译 {arch}: {source.relative_to(ROOT)}', flush=True)
        run([cxx, *flags, '-c', source, '-o', target])

    with ThreadPoolExecutor(max_workers=args.jobs) as executor:
        list(executor.map(compile_one, sources))
    # Both TSF architectures and the per-user agent share only the icon.
    # Settings additionally owns common-controls v6 / PerMonitorV2 activation.
    app_resource = obj / 'app-resource.o'
    run([windres, '-I', windows, '-i', windows / 'app.rc', '-o', app_resource])
    libs = ['-luser32', '-lgdi32', '-lole32', '-loleaut32', '-luuid', '-ladvapi32',
            '-lshell32', '-lbcrypt', '-lcrypt32', '-ld2d1', '-ldwrite',
            '-lwindowscodecs', '-lmsimg32']
    print(f'链接 {arch} TSF', flush=True)
    run([cxx, '-shared', '-static', '-Wl,--kill-at', '-o', out / 'GogakuTsf.dll',
         *[obj / f'{name}.o' for name in service + common], obj / 'settings_contract.o',
         obj / 'theme_contract.o', app_resource, tsf / 'gogaku_tsf.def', *panel_libs, *libs])
    if arch == 'x64':
        for name in ('monocypher', 'monocypher-ed25519'):
            run([cc, '-std=c11', '-O2', '-c', windows / 'third_party' / f'{name}.c',
                 '-o', obj / f'{name}.o'])
        run([cxx, '-static', '-municode', '-mwindows', '-o', out / 'GogakuAgent.exe',
             *[obj / f'{name}.o' for name in ('agent', 'services', 'platform', 'enable')],
             obj / 'settings_contract.o', app_resource, *libs, '-lwinhttp'])
        settings_resource = obj / 'settings-resource.o'
        run([windres, '-I', windows, '-i', windows / 'settings.rc', '-o', settings_resource])
        run([cxx, '-static', '-municode', '-mwindows', '-o', out / 'GogakuSettings.exe',
             *[obj / f'{name}.o' for name in ('settings', 'services', 'update', 'dictionaries',
                 'platform', 'appearance', 'themes', 'enable', 'monocypher', 'monocypher-ed25519')],
             obj / 'settings_contract.o', obj / 'theme_contract.o', settings_resource,
             *panel_libs, *libs, '-lwinhttp', '-lcomctl32', '-lcomdlg32', '-luxtheme'])
    # 自检单独放在 tests/；不混入安装包或发行收据。这里只编译，不执行。
    test_out = args.out / 'tests' / arch
    test_out.mkdir(parents=True, exist_ok=True)
    run([cxx, *flags, ROOT / 'shared/GogakuCore/tests/panel_render_test.cpp',
         '-static', '-o', test_out / 'gogaku_core_panel_render_test.exe', *panel_libs])
    run([cxx, *flags, ROOT / 'windows/tests/appearance_test.cpp',
         *[obj / f'{name}.o' for name in common], obj / 'settings_contract.o', obj / 'theme_contract.o',
         '-static', '-o', test_out / 'gogaku_windows_appearance_test.exe', *panel_libs, *libs])
    # 只读自检：身份条目串、通道区分与探测口径；不写 HKCU、不启用输入法。
    run([cxx, *flags, ROOT / 'windows/tests/enable_test.cpp', obj / 'enable.o',
         obj / 'platform.o', obj / 'settings_contract.o',
         '-static', '-o', test_out / 'gogaku_windows_enable_test.exe', *libs])
    for artifact in sorted(out.glob('*')):
        if artifact.suffix.lower() in ('.dll', '.exe'):
            print(f'产物：{artifact} ({artifact.stat().st_size:,} bytes)', flush=True)


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--arch', choices=['x64', 'x86', 'all'], default='all')
    p.add_argument('--channel', choices=['dev', 'stable'], default='dev')
    p.add_argument('--flavor', choices=['full', 'lite'], default='full')
    p.add_argument('--jobs', type=int, default=3)
    p.add_argument('--out', type=Path)
    p.add_argument('--core-build', type=Path, default=ROOT / '.build/win-cross/static/setup-core-io')
    p.add_argument('--deps', type=Path, default=ROOT / '.build/win-cross/static/deps-root')
    p.add_argument('--sysroot', type=Path, default=ROOT / '.build/win-cross/msys-sysroot/clang64')
    p.add_argument('--toolchain', type=Path, default=ROOT / '.build/win-cross/static/toolchain-dll.cmake')
    p.add_argument('--skip-core', action='store_true')
    args = p.parse_args()
    args.out = (args.out or ROOT / '.build/win-app' / args.channel).resolve()
    if args.jobs < 1:
        p.error('--jobs 必须为正整数')
    meta = json.loads((ROOT / 'version.json').read_text())
    stage = 'dev' if '-dev.' in meta['version'] else 'release'
    git = git_identity(ROOT)
    dirty = git['dirty']
    if stage != 'dev' and dirty:
        p.error('定版构建要求工作区干净；开发测试请在 version.json 使用 dev 版本')
    if args.channel == 'stable' and '-' in meta['version']:
        p.error('stable 通道要求 version.json 中为正式版本')
    source = source_fingerprint(ROOT)
    arches = ('x64', 'x86') if args.arch == 'all' else (args.arch,)
    if args.skip_core and 'x64' in arches:
        # 跳过核心只允许复用已证明来自相同输入的产物，不能为旧 DLL 盖新身份。
        validate_compile_receipt(args.out / 'bin/x64/build-receipt.json',
                                 args.out / 'bin/x64', args.channel, 'x64', source=source)
    for arch in arches:
        (args.out / 'bin' / arch / 'build-receipt.json').unlink(missing_ok=True)
    if args.arch in ('all', 'x64') and not args.skip_core:
        if not args.deps.is_dir() or not args.toolchain.is_file():
            p.error('缺少静态 libime 依赖或 MinGW toolchain；先准备 Windows 交叉依赖')
        link = '-static ' + ' '.join('-L' + str(path) for path in
            (args.sysroot / 'lib', args.deps / 'build/bin', args.deps / 'prefix/lib'))
        core_flags = ['cmake', '-S', ROOT / 'shared/GogakuCore', '-B', args.core_build, '-G', 'Ninja',
                      f'-DCMAKE_TOOLCHAIN_FILE={args.toolchain}', f'-DGOGAKU_DEPS={args.deps}',
                      '-DCMAKE_BUILD_TYPE=Release', f'-DCMAKE_SHARED_LINKER_FLAGS={link}',
                      '-DGOGAKU_LITE=ON' if args.flavor == 'lite' else '-DGOGAKU_LITE=OFF',
                      '-DGOGAKU_PANEL_RENDER=ON', '-DGOGAKU_PANEL_EXPORTS=ON']
        run(core_flags)
        run(['cmake', '--build', args.core_build, '--target', 'GogakuCore', '-j', args.jobs])
        core_out = args.out / 'bin/x64'
        core_out.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(args.core_build / 'bin/libgogaku_core.dll', core_out / 'libgogaku_core.dll')
    dependencies = {}
    if 'x64' in arches:
        if not args.toolchain.is_file():
            p.error('缺少 DLL toolchain；运行 scripts/prepare-win-setup.py')
        dependency_paths = {args.toolchain.resolve()}
        for folder in (args.sysroot / 'lib', args.deps / 'build/bin', args.deps / 'prefix/lib'):
            dependency_paths.update(path.resolve() for path in folder.rglob('*.a'))
        dependencies = {str(path): sha256(path) for path in sorted(dependency_paths)}
    for arch in arches:
        compile_arch(args, arch)
    if source_fingerprint(ROOT) != source or any(sha256(Path(p)) != h for p, h in dependencies.items()):
        raise DeliveryError('编译期间源码／资源／依赖变化；未生成编译收据，请重试')
    for arch in arches:
        folder = args.out / 'bin' / arch
        names = ['GogakuTsf.dll']
        if arch == 'x64':
            names += ['GogakuAgent.exe', 'GogakuSettings.exe', 'libgogaku_core.dll']
        receipt = dict(schema=1, fullVersion=meta['version'], buildNumber=meta['buildNumber'],
                       channel=args.channel, flavor=args.flavor,
                       arch=arch, configuration='release', git=git,
                       sourceSha256=source, dependencies=dependencies if arch == 'x64' else {},
                       artifacts={name: {'sha256': sha256(folder / name),
                                         'bytes': (folder / name).stat().st_size} for name in names})
        write_json(folder / 'build-receipt.json', receipt)
    print('编译完成并写入各架构收据；未运行 Windows 程序。')


if __name__ == '__main__':
    try:
        main()
    except subprocess.CalledProcessError as error:
        sys.exit(error.returncode)
    except DeliveryError as error:
        sys.exit(str(error))
