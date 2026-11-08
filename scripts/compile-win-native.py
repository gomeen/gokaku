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


def compile_arch(args, arch):
    prefix = 'x86_64-w64-mingw32' if arch == 'x64' else 'i686-w64-mingw32'
    cxx, cc, windres = prefix + '-g++', prefix + '-gcc', prefix + '-windres'
    for tool in (cxx, cc, windres):
        if not shutil.which(tool):
            raise SystemExit(f'缺少交叉编译器：{tool}')
    out = args.out / 'bin' / arch
    obj = args.out / ('obj64' if arch == 'x64' else 'obj32')
    out.mkdir(parents=True, exist_ok=True)
    obj.mkdir(parents=True, exist_ok=True)
    flags = ['-std=c++20', '-O2', '-DNDEBUG', '-DNOMINMAX', '-D_WIN32_WINNT=0x0A00',
             '-DUNICODE', '-D_UNICODE', '-fmax-errors=3', '-fdiagnostics-plain-output',
             # 设置契约实现直接编进各 Windows 二进制（x86 TSF 无法加载 x64 核心 DLL）。
             '-DGOGAKU_SETTINGS_CONTRACT_STATIC',
             f'-DGOGAKU_CHANNEL="{args.channel}"']
    if args.channel == 'dev':
        flags.append('-DGOGAKU_DEV')
    windows = ROOT / 'windows/GogakuWindows'
    tsf = ROOT / 'windows/GogakuTsf'
    common = ['platform', 'appearance', 'themes']
    service = ['dllmain', 'text_service', 'candidate_window', 'core_bridge']
    sources = [(windows / f'{name}.cpp', obj / f'{name}.o') for name in common]
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
         obj / 'theme_contract.o', app_resource, tsf / 'gogaku_tsf.def', *libs])
    if arch == 'x64':
        for name in ('monocypher', 'monocypher-ed25519'):
            run([cc, '-std=c11', '-O2', '-c', windows / 'third_party' / f'{name}.c',
                 '-o', obj / f'{name}.o'])
        run([cxx, '-static', '-municode', '-mwindows', '-o', out / 'GogakuAgent.exe',
             *[obj / f'{name}.o' for name in ('agent', 'services', 'platform')],
             obj / 'settings_contract.o', app_resource, *libs, '-lwinhttp'])
        settings_resource = obj / 'settings-resource.o'
        run([windres, '-I', windows, '-i', windows / 'settings.rc', '-o', settings_resource])
        run([cxx, '-static', '-municode', '-mwindows', '-o', out / 'GogakuSettings.exe',
             *[obj / f'{name}.o' for name in ('settings', 'services', 'update',
                 'platform', 'appearance', 'themes', 'monocypher', 'monocypher-ed25519')],
             obj / 'settings_contract.o', obj / 'theme_contract.o', settings_resource,
             *libs, '-lwinhttp', '-lcomctl32', '-lcomdlg32', '-luxtheme'])
    for artifact in sorted(out.glob('*')):
        if artifact.suffix.lower() in ('.dll', '.exe'):
            print(f'产物：{artifact} ({artifact.stat().st_size:,} bytes)', flush=True)


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--arch', choices=['x64', 'x86', 'all'], default='all')
    p.add_argument('--channel', choices=['dev', 'stable'], default='dev')
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
        p.error('rc／定版构建要求工作区干净；开发测试请在 version.json 使用 dev 版本')
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
        run(['cmake', '-S', ROOT / 'shared/GogakuCore', '-B', args.core_build, '-G', 'Ninja',
             f'-DCMAKE_TOOLCHAIN_FILE={args.toolchain}', f'-DGOGAKU_DEPS={args.deps}',
             '-DCMAKE_BUILD_TYPE=Release', f'-DCMAKE_SHARED_LINKER_FLAGS={link}'])
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
                       channel=args.channel, arch=arch, configuration='release', git=git,
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
