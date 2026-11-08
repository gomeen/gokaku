#!/usr/bin/env python3
"""Windows（MSYS2 Clang64）libime 依赖准备：与 Mac 同 pin、同源数据、同上游转换命令。

产出 GOGAKU_DEPS 目录（source/ ecm-source/ fcitx5-source/ build/ prefix/ data/
manifest.json），供 shared/GogakuCore 的 CMake 直接使用（-DGOGAKU_DEPS）。

与 probes/prepare-libime-input.py（Mac 版）的关系：
- pin 完全同源（libime/fcitx5/ECM/kenlm 提交与数据档案 SHA256 从同一模块导入，
  不另立第二套 pin）；
- 构建与数据转换命令同源（ECM → 隔离 Fcitx5Utils → IMEPinyin＋两个数据工具；
  工厂数据用上游原命令 -s -a 22 -q 4 trie 生成，无数据替代）；
- 差异仅在平台：不构建探针 worker、不做 brew 记录；MSYS2 Clang64 的 boost
  走 pacman。产物哈希单独记录——KenLM／词库格式跨平台兼容性以 CI 上核心
  测试向量（普通＋学习＋ABI＋加固层）全绿为验证口径，不假设 Mac 产物可用。

状态：脚手架。在首次 MSYS2／CI（.github/workflows/windows-core.yml）真实运行
之前未经验证；首跑可能暴露工具链差异（osyncstream／libc++ 开关／路径形态），
按失败逐项修，不在本机宣称通过。

用法（在 MSYS2 CLANG64 shell 内）：
  python scripts/prepare-libime-windows.py [--jobs 4] [--root <dir>]
环境：GOGAKU_DEPS 可指定目标目录（默认 ./deps-libime-1.1.17）。
"""
import argparse
import importlib.util
import json
import os
import platform
import shutil
import subprocess
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
# pins 单一来源：从 Mac 探针模块导入（exec 只执行常量与函数定义，main 有 __main__ 守卫）。
spec = importlib.util.spec_from_file_location(
    'libime_builder', REPO / 'probes' / 'prepare-libime-input.py')
builder = importlib.util.module_from_spec(spec)
spec.loader.exec_module(builder)

REQUIRED_TOOLS = ['git', 'cmake', 'ninja', 'clang++', 'tar', 'zstd']


def capture(args):
    return subprocess.check_output([str(a) for a in args], text=True).strip()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--jobs', type=int, default=4)
    parser.add_argument('--root', default=os.environ.get('GOGAKU_DEPS') or 'deps-libime-1.1.17')
    args = parser.parse_args()

    if sys.platform != 'win32':
        raise SystemExit('本脚本面向 Windows（MSYS2 Clang64）；Mac 用 scripts/prepare-dependencies.py')
    if os.environ.get('MSYSTEM') != 'CLANG64':
        raise SystemExit('请在 MSYS2 CLANG64 shell 内运行（MSYSTEM=CLANG64）；'
                         '工具链与 boost 均须来自 Clang64，不混用 MSVC／MinGW 等 runtime')
    missing = [tool for tool in REQUIRED_TOOLS if shutil.which(tool) is None]
    if missing:
        raise SystemExit('缺少工具：' + '、'.join(missing) +
                         '（pacman -S git mingw-w64-clang-x86_64-toolchain '
                         'mingw-w64-clang-x86_64-boost zstd）')

    root = Path(args.root).resolve()
    root.mkdir(parents=True, exist_ok=True)
    builder.ROOT = root
    builder.MANIFEST.clear()
    builder.MANIFEST.update({
        'id': 'I0-WIN', 'engine': 'libime', 'version': '1.1.17', 'commit': builder.COMMIT,
        'status': 'preparing', 'command': [], 'build_commands': [], 'sources': [],
        'data': [], 'licenses': [], 'adjustments': [], 'formal_performance_run': False,
        'platform': f'{platform.system()} {platform.release()} MSYS2 {os.environ.get("MSYSTEM")}',
        'compiler': capture(['clang++', '--version']),
        'adjustments_note': 'Windows 侧产物哈希单独记录；与 Mac 产物一致性以 CI 核心测试向量全绿为准',
    })

    # MSYS2 前缀：cmake（原生 Windows 构建）需要 Windows 形态路径。
    msys_prefix = os.environ.get('MINGW_PREFIX', '/clang64')
    if shutil.which('cygpath'):
        clang64 = capture(['cygpath', '-m', msys_prefix])
    else:
        clang64 = msys_prefix
    boost_include = Path(clang64) / 'include'
    if not (boost_include / 'boost' / 'version.hpp').exists():
        raise SystemExit(f'未找到 boost 头文件 {boost_include}（pacman -S '
                         'mingw-w64-clang-x86_64-boost）')

    source = builder.checkout('https://github.com/fcitx/libime.git', 'source', builder.COMMIT)
    builder.license_file(source / 'LICENSES/LGPL-2.1-or-later.txt',
                         'LGPL-2.1-or-later', 'libime source and factory data')
    data = builder.download_data(source)
    builder.run(['git', '-C', source, 'submodule', 'update', '--init', '--depth', '1'], 'kenlm-fetch')
    kenlm = source / 'src/libime/core/kenlm'
    if capture(['git', '-C', kenlm, 'rev-parse', 'HEAD']) != builder.KENLM:
        raise SystemExit('kenlm 子模块提交与 pin 不符')
    builder.MANIFEST['sources'].append(
        {'url': 'https://github.com/kpu/kenlm.git', 'commit': builder.KENLM, 'path': str(kenlm)})
    for name in ['COPYING', 'COPYING.3', 'COPYING.LESSER.3']:
        builder.license_file(kenlm / name, 'LGPL-2.1-or-later and per-file notices', 'bundled kenlm')
    builder.patch_kenlm_cxx20(source)

    ecm = builder.checkout('https://github.com/KDE/extra-cmake-modules.git',
                           'ecm-source', builder.ECM)
    builder.license_file(ecm / 'COPYING-CMAKE-SCRIPTS', 'BSD-3-Clause', 'extra-cmake-modules')
    fcitx = builder.checkout('https://github.com/fcitx/fcitx5.git', 'fcitx5-source', builder.FCITX)
    builder.license_file(fcitx / 'LICENSES/LGPL-2.1-or-later.txt', 'LGPL-2.1-or-later', 'Fcitx5Utils')
    builder.license_file(fcitx / 'LICENSES/Unicode-DFS-2016.txt',
                         'Unicode-DFS-2016', 'Fcitx5Utils Unicode data')

    prefix = root / 'prefix'
    builder.run(['cmake', '-S', ecm, '-B', root / 'ecm-build', '-G', 'Ninja',
                 f'-DCMAKE_INSTALL_PREFIX={prefix}', '-DBUILD_TESTING=OFF', '-DBUILD_DOC=OFF'],
                'ecm-configure')
    builder.run(['cmake', '--install', root / 'ecm-build'], 'ecm-install')
    options = ['ENABLE_TEST', 'ENABLE_TESTING_ADDONS', 'ENABLE_X11', 'ENABLE_WAYLAND',
               'ENABLE_DBUS', 'ENABLE_ENCHANT', 'ENABLE_SERVER', 'ENABLE_KEYBOARD',
               'ENABLE_EMOJI', 'ENABLE_LIBUUID', 'BUILD_SPELL_DICT', 'ENABLE_XDGAUTOSTART']
    builder.run(['cmake', '-S', fcitx, '-B', root / 'fcitx5-build', '-G', 'Ninja',
                 '-DCMAKE_BUILD_TYPE=Release',
                 f'-DCMAKE_INSTALL_PREFIX={prefix}', f'-DCMAKE_PREFIX_PATH={prefix}',
                 '-DCMAKE_CXX_FLAGS=-fexperimental-library', '-DEVENT_LOOP_BACKEND=none',
                 *['-D' + option + '=OFF' for option in options]], 'fcitx-configure')
    builder.run(['cmake', '--build', root / 'fcitx5-build', '--target', 'Fcitx5Utils',
                 '-j', args.jobs], 'fcitx-build')
    builder.run(['cmake', '--install', root / 'fcitx5-build/src/lib/fcitx-utils'], 'fcitx-install')
    builder.run(['cmake', '-S', source, '-B', root / 'build', '-G', 'Ninja',
                 '-DCMAKE_BUILD_TYPE=Release',
                 f'-DCMAKE_INSTALL_PREFIX={prefix}', f'-DCMAKE_PREFIX_PATH={prefix}',
                 '-DENABLE_TEST=OFF', '-DENABLE_DATA=OFF', '-DENABLE_DOC=OFF',
                 '-DENABLE_TOOLS=ON',
                 # clang64 libc++ 同样可按需保留 std::binary_function（pinned kenlm 依赖）。
                 '-DCMAKE_CXX_FLAGS=-D_LIBCPP_ENABLE_CXX17_REMOVED_UNARY_BINARY_FUNCTION',
                 f'-DBOOST_INCLUDEDIR={boost_include}'], 'libime-configure')
    builder.run(['cmake', '--build', root / 'build', '--target', 'IMEPinyin',
                 'libime_pinyindict', 'libime_slm_build_binary', '-j', args.jobs], 'libime-build')
    if not (data / 'sc.dict').exists():
        builder.run([root / 'build' / 'bin' / 'libime_pinyindict',
                     data / 'dict_sc.txt', data / 'sc.dict'], 'dict-convert')
    if not (data / 'zh_CN.lm').exists():
        builder.run([root / 'build' / 'bin' / 'libime_slm_build_binary', '-s', '-a', '22',
                     '-q', '4', 'trie', data / 'lm_sc.arpa', data / 'zh_CN.lm'], 'lm-convert')

    builder.MANIFEST['artifacts'] = [
        {'path': str(path), 'sha256': builder.digest(path), 'bytes': path.stat().st_size}
        for path in [root / 'data' / 'sc.dict', root / 'data' / 'zh_CN.lm']
    ]
    builder.MANIFEST['status'] = 'built'
    builder.save()
    print('Windows 依赖就绪：' + str(root))
    print('核心构建与测试（CI 同款）：')
    print(f'  export GOGAKU_DEPS="{root}"')
    print('  cmake --preset clang64 -S shared/GogakuCore')
    print('  cmake --build --preset clang64')
    print(f'  GOGAKU_CORE_TEST_DATA="{root / "data"}" ctest --test-dir .build/core-windows --output-on-failure')


if __name__ == '__main__':
    main()
