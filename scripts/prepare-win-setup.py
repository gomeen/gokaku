#!/usr/bin/env python3
"""准备 Intel macOS → Windows Setup 的固定输入，不安装工具、不运行 Windows 程序。

两阶段（可从干净 checkout 执行）：
  python3 scripts/prepare-win-setup.py --stage deps --download
  python3 scripts/prepare-win-setup.py --stage setup --download
--download 仅允许缺失的源码／MSYS2 小包／许可联网；默认只使用校验过的缓存。
--plan 完全只读；--tools-help 打印 Wine/Inno 的固定下载和人工安装指令。
中文出厂数据复用 prepare-dependencies.py 的冻结产物；缺失时明确提示生成命令，
不会隐式下载大数据。Wine/Inno 工具必须由用户显式准备；本入口只生成 wrapper。
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import shlex
import shutil
import subprocess
import sys
import tempfile
import urllib.request

ROOT = Path(__file__).resolve().parent.parent
LOCK_FILE = ROOT / 'scripts/windows-setup-dependencies.lock.json'
WC = ROOT / '.build/win-cross'
SC = WC / 'static'
SOURCES = WC / 'setup-sources'
TOOLS = ROOT / '.build/win-tools'


class PreparationError(RuntimeError):
    pass


def sha256(path):
    with Path(path).open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def verify(path, expected):
    if not path.is_file() or sha256(path) != expected:
        raise PreparationError(f'缺失或 SHA-256 不符：{path}（预期 {expected}）；不使用替代版本')


def run(command, **kwargs):
    print('+ ' + shlex.join([str(x) for x in command]), flush=True)
    subprocess.run([str(x) for x in command], check=True, **kwargs)


def capture(command):
    return subprocess.check_output([str(x) for x in command], text=True).strip()


def put(path, text):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text, encoding='utf-8')


def copy(source, target):
    if not source.is_file() or not source.stat().st_size:
        raise PreparationError(f'缺少资源／实际许可：{source}')
    target.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(source, target)


def download(entry, target, allowed, candidates=()):
    if target.exists():
        verify(target, entry['sha256'])
        return target
    for candidate in candidates:
        if candidate.is_file() and sha256(candidate) == entry['sha256']:
            copy(candidate, target)
            return target
    if not allowed:
        raise PreparationError(f'缓存缺失：{target}\n重跑当前命令并加 --download；固定来源 {entry["url"]}')
    target.parent.mkdir(parents=True, exist_ok=True)
    partial = target.with_name(target.name + '.partial')
    try:
        with urllib.request.urlopen(entry['url'], timeout=60) as response, partial.open('wb') as output:
            shutil.copyfileobj(response, output)
        verify(partial, entry['sha256'])
        partial.replace(target)
    finally:
        partial.unlink(missing_ok=True)
    return target


def require_tools(boost):
    names = ['git', 'cmake', 'ninja', 'pkg-config', 'tar']
    names += [f'{arch}-w64-mingw32-{tool}' for arch in ('x86_64', 'i686')
              for tool in ('gcc', 'g++', 'windres')]
    names += ['x86_64-w64-mingw32-ar', 'x86_64-w64-mingw32-ranlib']
    missing = [name for name in names if not shutil.which(name)]
    if missing or not (boost / 'include/boost/version.hpp').is_file():
        raise PreparationError('缺少本机工具／Boost 头文件：' + ', '.join(missing or [str(boost)]) +
                               '\n请自行执行：brew install mingw-w64 cmake ninja pkgconf boost'
                               '\n自定义 Boost 前缀可传 --boost；本入口不执行 brew。')
    return {name: Path(shutil.which(name)) for name in names}


def checkout(name, entry, target, args):
    if not (target / '.git').exists():
        # 只取固定 Git 对象，绝不复制缓存工作树中不明来源的补丁／toolchain。
        candidates = [WC / 'deps' / name, SC / name,
                      args.native_deps / {'libime': 'source', 'fcitx5': 'fcitx5-source',
                                          'ecm': 'ecm-source', 'kenlm': 'source/src/libime/core/kenlm'}[name]]
        if name == 'kenlm':
            candidates.insert(0, WC / 'deps/libime/src/libime/core/kenlm')
        local = next((p for p in candidates if (p / '.git').exists() and
                      subprocess.run(['git', '-C', str(p), 'cat-file', '-e', entry['commit']],
                                     stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode == 0), None)
        if local is None and not args.download:
            raise PreparationError(f'缺少 {name} 固定源码 {entry["commit"]}；重跑 --stage deps --download')
        run(['git', 'init', '-q', target])
        run(['git', '-C', target, 'fetch', '-q', '--depth', '1', local or entry['url'], entry['commit']])
        run(['git', '-C', target, 'checkout', '-q', '--detach', entry['commit']])
    if capture(['git', '-C', target, 'rev-parse', 'HEAD']) != entry['commit']:
        raise PreparationError(f'{target} 提交不符；请移走该生成目录后重跑 --stage deps')
    if capture(['git', '-C', target, 'status', '--porcelain', '--untracked-files=all']):
        raise PreparationError(f'固定源码树不干净：{target}；请移走该生成目录后重跑 --stage deps')


def cmake_quote(value):
    return '"' + str(value).replace('\\', '/').replace('"', '\\"').replace(';', '\\;') + '"'


def toolchain(tools, boost, *, shared):
    sysroot = WC / 'msys-sysroot/clang64'
    prefix = SC / 'setup-prefix'
    lines = ['# Generated by scripts/prepare-win-setup.py; not copied from .build.',
             'set(CMAKE_SYSTEM_NAME Windows)', 'set(CMAKE_SYSTEM_PROCESSOR AMD64)',
             'set(CMAKE_POLICY_DEFAULT_CMP0077 NEW)',
             f'set(BUILD_SHARED_LIBS {"ON" if shared else "OFF"} CACHE BOOL "" FORCE)']
    for variable, tool in [('C_COMPILER', 'gcc'), ('CXX_COMPILER', 'g++'),
                           ('RC_COMPILER', 'windres'), ('AR', 'ar'), ('RANLIB', 'ranlib')]:
        lines.append(f'set(CMAKE_{variable} {cmake_quote(tools["x86_64-w64-mingw32-" + tool])} CACHE FILEPATH "" FORCE)')
    # DLL consumers link static dependencies too; compile-win-native overrides SHARED flags with -static.
    libraries = [sysroot / 'lib', SC / 'deps-root/build/bin', prefix / 'lib']
    flags = '-static ' + ' '.join('-L' + shlex.quote(str(p)) for p in libraries)
    lines += [f'set(CMAKE_{kind}_LINKER_FLAGS_INIT {cmake_quote(flags)})' for kind in ('EXE', 'SHARED')]
    lines += ['set(CMAKE_CXX_STANDARD_LIBRARIES "-lzstd -lintl -liconv -ldl -lz")',
              'set(CMAKE_FIND_ROOT_PATH ' + ' '.join(cmake_quote(p) for p in
                  [tools['x86_64-w64-mingw32-g++'].resolve().parent.parent / 'x86_64-w64-mingw32',
                   boost, sysroot, prefix]) + ')']
    lines += [f'set(CMAKE_FIND_ROOT_PATH_MODE_{kind} {mode})' for kind, mode in
              [('PROGRAM', 'NEVER'), ('LIBRARY', 'ONLY'), ('INCLUDE', 'ONLY'), ('PACKAGE', 'ONLY')]]
    return '\n'.join(lines) + '\n'


def prepare_deps(args, lock):
    tools = require_tools(args.boost)
    for name in ('libime', 'fcitx5', 'ecm'):
        checkout(name, lock['sources'][name], SOURCES / name, args)
    kenlm = SOURCES / 'libime/src/libime/core/kenlm'
    checkout('kenlm', lock['sources']['kenlm'], kenlm, args)
    sysroot = WC / 'msys-sysroot'
    # Always reconstruct the extracted tree: stale extra import libraries cannot win static lookup.
    archives = []
    for item in lock['msys2']:
        entry = dict(item, url='https://repo.msys2.org/mingw/clang64/' + item['file'])
        archives.append(download(entry, sysroot / item['file'], args.download))
    extracted = sysroot / 'clang64'
    if extracted.exists():
        shutil.rmtree(extracted)
    for archive in archives:
        run([tools['tar'], '--zstd', '-xf', archive, '-C', sysroot])
    for pc in extracted.glob('lib/pkgconfig/*.pc'):
        values = {'prefix': extracted, 'exec_prefix': extracted, 'libdir': extracted / 'lib',
                  'includedir': extracted / 'include', 'sharedlibdir': extracted / 'bin'}
        put(pc, '\n'.join(key + '=' + str(values[key]) if '=' in line and
                         (key := line.split('=', 1)[0]) in values else line
                         for line in pc.read_text().splitlines()) + '\n')
    for name in ('libz.a', 'libzstd.a', 'libintl.a', 'libiconv.a', 'libdl.a'):
        if not (extracted / 'lib' / name).is_file():
            raise PreparationError(f'MSYS2 包缺少静态库：{name}')
    # Build only in an owned subtree, never reuse unknown historical CMake caches.
    work = SC / 'setup-build'
    if work.exists():
        shutil.rmtree(work)
    work.mkdir(parents=True)
    src = work / 'libime'
    shutil.copytree(SOURCES / 'libime', src, ignore=shutil.ignore_patterns('.git'))
    run(['git', 'apply', '--check', ROOT / 'scripts/patches/libime-win-cross.patch'], cwd=src)
    run(['git', 'apply', ROOT / 'scripts/patches/libime-win-cross.patch'], cwd=src)
    prefix = SC / 'setup-prefix'
    if prefix.exists():
        shutil.rmtree(prefix)
    put(SC / 'toolchain-setup-static.cmake', toolchain(tools, args.boost, shared=False))
    # Installed static FcitxUtils exports refer to these private platform targets.
    prelude = ''.join(f'if(NOT TARGET {target})\n  add_library({target} INTERFACE IMPORTED)\n'
                      f'  set_property(TARGET {target} PROPERTY INTERFACE_LINK_LIBRARIES "{libs}")\nendif()\n'
                      for target, libs in [('DL::DL', 'dl'), ('LibIntl::LibIntl', 'intl;iconv'),
                                           ('Pthread::Pthread', 'pthread')])
    put(work / 'consumer-prelude.cmake', prelude)
    env = dict(os.environ, PKG_CONFIG_LIBDIR=str(extracted / 'lib/pkgconfig'), PKG_CONFIG_PATH='')

    def configure(source, output, options=()):
        run(['cmake', '-S', source, '-B', output, '-G', 'Ninja',
             f'-DCMAKE_MAKE_PROGRAM={tools["ninja"]}',
             f'-DCMAKE_TOOLCHAIN_FILE={SC / "toolchain-setup-static.cmake"}',
             '-DCMAKE_BUILD_TYPE=Release', '-DBUILD_SHARED_LIBS=OFF',
             f'-DCMAKE_INSTALL_PREFIX={prefix}', f'-DCMAKE_PREFIX_PATH={prefix}', *options], env=env)

    configure(SOURCES / 'ecm', work / 'ecm', ['-DBUILD_TESTING=OFF', '-DBUILD_DOC=OFF'])
    run(['cmake', '--install', work / 'ecm'])
    disabled = ['ENABLE_TEST', 'ENABLE_TESTING_ADDONS', 'ENABLE_X11', 'ENABLE_WAYLAND',
                'ENABLE_DBUS', 'ENABLE_ENCHANT', 'ENABLE_SERVER', 'ENABLE_KEYBOARD',
                'ENABLE_EMOJI', 'ENABLE_LIBUUID', 'BUILD_SPELL_DICT', 'ENABLE_XDGAUTOSTART']
    configure(SOURCES / 'fcitx5', work / 'fcitx5', ['-DEVENT_LOOP_BACKEND=none',
              *['-D' + name + '=OFF' for name in disabled]])
    run(['cmake', '--build', work / 'fcitx5', '--target', 'Fcitx5Utils', '-j', args.jobs])
    run(['cmake', '--install', work / 'fcitx5/src/lib/fcitx-utils'])
    configure(src, work / 'libime-build', ['-DENABLE_TEST=OFF', '-DENABLE_DATA=OFF',
              '-DENABLE_DOC=OFF', '-DENABLE_TOOLS=OFF', '-DCMAKE_SKIP_INSTALL_RULES=ON',
              f'-DCMAKE_PROJECT_INCLUDE={work / "consumer-prelude.cmake"}',
              f'-DBOOST_INCLUDEDIR={args.boost / "include"}'])
    run(['cmake', '--build', work / 'libime-build', '--target', 'IMEPinyin', '-j', args.jobs])
    for name, folder in [('libIMECore.a', 'libime-build'), ('libIMEPinyin.a', 'libime-build'),
                         ('libFcitx5Utils.a', 'fcitx5')]:
        matches = list((work / folder).rglob(name))
        if len(matches) != 1:
            raise PreparationError(f'静态依赖产物不唯一或缺失：{name} {matches}')
        copy(matches[0], work / 'libime-build/bin' / name)
    deps = SC / 'deps-root'
    deps.mkdir(exist_ok=True)
    for name, target in [('source', src), ('build', work / 'libime-build'), ('prefix', prefix)]:
        link = deps / name
        if link.exists() and not link.is_symlink():
            raise PreparationError(f'拒绝覆盖非符号链接：{link}；请先移走该路径')
        link.unlink(missing_ok=True)
        link.symlink_to(target, target_is_directory=True)
    put(SC / 'toolchain-dll.cmake', toolchain(tools, args.boost, shared=True))
    put(SC / 'setup-dependencies.json', json.dumps({'lockSha256': sha256(LOCK_FILE),
        'tools': {k: str(v.resolve()) for k, v in tools.items()},
        'archives': {p.name: sha256(p) for p in (work / 'libime-build/bin').glob('*.a')}}, indent=2) + '\n')
    print('静态依赖及默认 toolchain-dll.cmake 已生成；未编译／运行 Gogaku 或 Windows 程序。')


def tools_help(lock, args):
    print('以下仅打印，需用户显式执行；不关闭 Gatekeeper，不移除隔离属性。')
    for name in ('wine', 'inno'):
        item = lock[name]
        target = TOOLS / 'downloads' / item['url'].rsplit('/', 1)[1]
        print(shlex.join(['mkdir', '-p', str(target.parent)]))
        print(shlex.join(['curl', '-fL', '--output', str(target), item['url']]))
        print(shlex.join(['shasum', '-a', '256', str(target)]), '# 必须等于', item['sha256'])
    print('# 核对 Wine 归档摘要后解包（仅 Intel Mac；本入口不下载／安装／运行 Wine）：')
    print(shlex.join(['mkdir', '-p', str(TOOLS / 'wine')]))
    print(shlex.join(['tar', '-xf', str(TOOLS / 'downloads/wine-stable-11.0_1-osx64.tar.xz'), '-C', str(TOOLS / 'wine')]))
    print('# 仅在系统允许且用户同意时安装编译器到隔离目录；不运行 Gogaku Setup：')
    print(shlex.join(['env', f'WINEPREFIX={TOOLS / "prefix"}', 'WINEARCH=win64',
                     'WINEDLLOVERRIDES=winemenubuilder.exe=d;mscoree,mshtml=d', str(args.wine),
                     'Z:' + str(TOOLS / 'downloads/innosetup-6.7.4.exe').replace('/', '\\'),
                     '/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART', '/SP-', '/CURRENTUSER',
                     '/NOICONS', '/TASKS=', '/DIR=Z:' + str(args.inno_dir).replace('/', '\\')]))
    print('随后重跑 --stage setup。Inno 商业使用授权需另行核对 license.txt。')


def wrapper(wine, inno):
    return '''#!/usr/bin/env python3
# Generated by scripts/prepare-win-setup.py; only invoked by an explicit build.
import os
from pathlib import Path
import sys
root = Path(__file__).resolve().parent
wine = Path(%r)
compiler = Path(%r)
if not os.access(wine, os.X_OK) or not compiler.is_file():
    sys.exit('Wine/Inno 缺失；请运行 python3 scripts/prepare-win-setup.py --tools-help')
for name in ('prefix', 'cache', 'tmp'):
    (root / name).mkdir(parents=True, exist_ok=True)
args = ['Z:' + str(Path(a).resolve()).replace('/', '\\\\')
        if a.lower().endswith('.iss') and Path(a).is_file() else a for a in sys.argv[1:]]
env = dict(os.environ, WINEPREFIX=str(root / 'prefix'), WINEARCH='win64', WINEDEBUG='-all',
           WINEDLLOVERRIDES='winemenubuilder.exe=d;mscoree,mshtml=d',
           XDG_CACHE_HOME=str(root / 'cache'), TMPDIR=str(root / 'tmp'), MVK_CONFIG_LOG_LEVEL='0')
env['PATH'] = str(wine.parent) + os.pathsep + env.get('PATH', '')
os.execve(str(wine), [str(wine), str(compiler), *args], env)
''' % (str(wine), str(inno / 'ISCC.exe'))


def setup_inputs(args, lock):
    for name, expected in lock['data'].items():
        try:
            verify(args.native_deps / 'data' / name, expected)
        except PreparationError as error:
            raise PreparationError(f'{error}\n先显式生成权威出厂数据（会下载大数据）：\n' +
                shlex.join(['env', f'GOGAKU_DEPS={args.native_deps}', 'python3',
                            str(ROOT / 'scripts/prepare-dependencies.py')])) from error
    for name, manifest in [('english-words.txt', 'english-wordlist-sources.json'),
                           ('gloss.tsv', 'gloss-sources.json')]:
        verify(ROOT / 'resources' / name,
               json.loads((ROOT / 'resources' / manifest).read_text())['output_sha256'])
    for name, entry in lock['sources'].items():
        path = SOURCES / ('libime/src/libime/core/kenlm' if name == 'kenlm' else name)
        if not (path / '.git').exists() or capture(['git', '-C', path, 'rev-parse', 'HEAD']) != entry['commit']:
            raise PreparationError('先运行 python3 scripts/prepare-win-setup.py --stage deps [--download]')
        if capture(['git', '-C', path, 'status', '--porcelain', '--untracked-files=all']):
            raise PreparationError(f'固定源码树不干净：{path}')
    if not os.access(args.wine, os.X_OK):
        raise PreparationError(f'缺少 Wine：{args.wine}；运行 --tools-help 获取固定版本准备指令')
    for name, digest in lock['inno']['files'].items():
        try:
            verify(args.inno_dir / name, digest)
        except PreparationError as error:
            raise PreparationError(f'{error}\n运行 --tools-help 准备官方 Inno 6.7.4；不自动运行 Wine。') from error


def prepare_setup(args, lock):
    setup_inputs(args, lock)
    # Rebuild staging rather than merge stale licenses / data. No bin files are touched.
    with tempfile.TemporaryDirectory(prefix='gogaku-win-setup-') as temporary:
        staging = Path(temporary)
        for name in lock['data']:
            copy(args.native_deps / 'data' / name, staging / 'data' / name)
        for name in ('english-words.txt', 'gloss.tsv', 'english-wordlist-sources.json', 'gloss-sources.json'):
            copy(ROOT / 'resources' / name, staging / 'data' / name)
        licenses = staging / 'licenses'
        for source, destination in [(ROOT / 'native/licenses', 'native'),
                                    (ROOT / 'resources/licenses', 'resources'),
                                    (WC / 'msys-sysroot/clang64/share/licenses', 'msys2')]:
            if not source.is_dir() or not any(source.rglob('*')):
                raise PreparationError(f'缺少许可来源：{source}；先运行 --stage deps')
            shutil.copytree(source, licenses / destination)
        files = {
            'libime/LICENSES/LGPL-2.1-or-later.txt': 'libime/LGPL-2.1-or-later.txt',
            'libime/REUSE.toml': 'libime/REUSE.toml', 'libime/data/CMakeLists.txt': 'libime/data-CMakeLists.txt',
            'fcitx5/LICENSES/LGPL-2.1-or-later.txt': 'fcitx5/LGPL-2.1-or-later.txt',
            'fcitx5/LICENSES/Unicode-DFS-2016.txt': 'fcitx5/Unicode-DFS-2016.txt',
            'ecm/COPYING-CMAKE-SCRIPTS': 'ecm/COPYING-CMAKE-SCRIPTS'}
        for name in ('COPYING', 'COPYING.3', 'COPYING.LESSER.3', 'LICENSE',
                     'util/murmur_hash.cc', 'util/string_piece.hh', 'util/getopt.c'):
            files['libime/src/libime/core/kenlm/' + name] = 'kenlm/' + name
        files['libime/src/libime/core/kenlm/util/integer_to_string.cc'] = 'kenlm/util/integer_to_string.cc'
        for source, target in files.items():
            copy(SOURCES / source, licenses / target)
        for name in ('json-LICENSE.MIT', 'miniz-LICENSE.txt', 'monocypher-LICENCE.md'):
            copy(ROOT / 'native/GogakuWindows/third_party' / name, licenses / 'windows' / name)
        for entry in lock['runtime_licenses']:
            candidate = Path('/usr/local/opt/mingw-w64') / {
                'MinGW-w64-COPYING.txt': 'COPYING', 'MinGW-w64-AUTHORS.txt': 'AUTHORS'}.get(entry['file'], entry['file'])
            cached = download(entry, TOOLS / 'downloads' / entry['file'], args.download,
                              [candidate, args.out / 'licenses' / entry['file']])
            copy(cached, licenses / entry['file'])
        copy(ROOT / 'docs/third-party.md', licenses / 'THIRD-PARTY.md')
        copy(LOCK_FILE, licenses / LOCK_FILE.name)
        copy(args.inno_dir / 'license.txt', licenses / 'inno/license.txt')
        put(licenses / 'windows-runtime-sources.json', json.dumps(lock['runtime_licenses'], indent=2) + '\n')
        for name in ('data', 'licenses'):
            target = args.out / name
            if target.exists():
                shutil.rmtree(target)
            shutil.copytree(staging / name, target)
    put(TOOLS / 'iscc', wrapper(args.wine, args.inno_dir))
    (TOOLS / 'iscc').chmod(0o755)
    print('Setup staging 已刷新，wrapper 已生成；未调用 Wine/ISCC，尚未构包或运行验收。')
    print(shlex.join(['python3', 'scripts/compile-win-native.py', '--arch', 'all', '--channel', args.channel]))
    print(shlex.join(['python3', 'scripts/build-win-app.py', '--channel', args.channel,
                     '--bin-dir', str(args.out / 'bin'), '--data-dir', str(args.out / 'data'),
                     '--license-dir', str(args.out / 'licenses'), '--deps-source-dir', str(SOURCES),
                     '--iscc', str(TOOLS / 'iscc')]))


def self_test():
    # No network, brew, compilers or Wine; verify negative paths and generated contracts.
    with tempfile.TemporaryDirectory() as directory:
        root = Path(directory)
        p = root / 'input'
        p.write_bytes(b'locked')
        verify(p, hashlib.sha256(b'locked').hexdigest())
        try:
            verify(p, '0' * 64)
        except PreparationError:
            pass
        else:
            raise AssertionError('digest mismatch accepted')
        try:
            download({'url': 'https://invalid.example/file', 'sha256': '0' * 64}, root / 'missing', False)
        except PreparationError:
            pass
        else:
            raise AssertionError('offline missing input accepted')
        fake = {f'x86_64-w64-mingw32-{t}': root / 'tool bin' / t
                for t in ('gcc', 'g++', 'windres', 'ar', 'ranlib')}
        static = toolchain(fake, root / 'boost', shared=False)
        dll = toolchain(fake, root / 'boost', shared=True)
        assert 'set(BUILD_SHARED_LIBS OFF CACHE BOOL "" FORCE)' in static
        assert 'set(BUILD_SHARED_LIBS ON CACHE BOOL "" FORCE)' in dll
        assert '-static ' in dll and 'CMAKE_CXX_STANDARD_LIBRARIES' in dll
        assert 'tool bin' in dll and '$REAL' not in dll
        compile(wrapper(root / 'Wine Stable.app/wine', root / 'inno'), 'iscc', 'exec')
    print('prepare-win-setup self-test passed（摘要拒绝、离线失败、双工具链及 wrapper 语法）。')


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--stage', choices=['deps', 'setup', 'all'], default='all')
    parser.add_argument('--channel', choices=['dev', 'stable'], default='dev')
    parser.add_argument('--download', action='store_true', help='显式允许固定源码、小包及许可下载；不下载 Wine／Inno／大数据')
    parser.add_argument('--plan', action='store_true', help='只读显示准备范围和缺失工具，不执行命令／写文件／联网')
    parser.add_argument('--tools-help', action='store_true')
    parser.add_argument('--self-test', action='store_true')
    parser.add_argument('--jobs', type=int, default=3)
    parser.add_argument('--boost', type=Path, default=Path('/usr/local/opt/boost'))
    parser.add_argument('--native-deps', type=Path, default=Path(os.environ.get('GOGAKU_DEPS',
                        Path.home() / 'Library/Caches/Gogaku/libime-1.1.17')))
    parser.add_argument('--out', type=Path, help='Setup staging 目录；默认 .build/win-app/<channel>')
    parser.add_argument('--wine', type=Path, default=TOOLS / 'wine/Wine Stable.app/Contents/Resources/wine/bin/wine')
    parser.add_argument('--inno-dir', type=Path, default=TOOLS / 'inno')
    args = parser.parse_args()
    if args.jobs < 1:
        parser.error('--jobs 必须为正整数')
    args.out = (args.out or ROOT / '.build/win-app' / args.channel).resolve()
    for name in ('boost', 'native_deps', 'wine', 'inno_dir'):
        setattr(args, name, getattr(args, name).expanduser().absolute())
    lock = json.loads(LOCK_FILE.read_text())
    if args.self_test:
        self_test()
        return
    if args.tools_help:
        tools_help(lock, args)
        return
    if platform.system() != 'Darwin' or platform.machine() != 'x86_64':
        raise PreparationError('当前准备入口仅支持 Intel macOS；不安装或模拟其他平台。')
    if args.plan:
        print('只读计划，不代表环境已准备完成；不下载／构建／运行 Wine。')
        print('deps: 固定 Git 源码 → MSYS2 摘要校验／解包 → ECM → 静态 Fcitx5Utils/IMECore/IMEPinyin')
        print(f'      {SC / "toolchain-dll.cmake"} + {SC / "deps-root"}')
        print(f'setup: 校验 {args.native_deps / "data"} 及仓库英文／释义 → {args.out}/{{data,licenses}}')
        print(f'       固定 Inno 6.7.4 校验 → {TOOLS / "iscc"}')
        for check in (lambda: require_tools(args.boost), lambda: setup_inputs(args, lock)):
            try:
                check()
            except PreparationError as error:
                print('前置缺口：' + str(error))
        print('工具准备指令：python3 scripts/prepare-win-setup.py --tools-help')
        return
    if args.stage in ('deps', 'all'):
        prepare_deps(args, lock)
    if args.stage in ('setup', 'all'):
        prepare_setup(args, lock)


if __name__ == '__main__':
    try:
        main()
    except (PreparationError, subprocess.CalledProcessError, OSError) as error:
        sys.exit('Windows 准备失败：' + str(error))
