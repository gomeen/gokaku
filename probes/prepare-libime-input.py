#!/usr/bin/env python3
"""在 /tmp 隔离准备 libime I0；仅构建和正确性冒烟，不运行正式性能测试。"""
import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import platform
import shlex
import subprocess
import sys
import tomllib
import urllib.request

sys.dont_write_bytecode = True  # 核对生成器时不在 probes 下产生 __pycache__。

ROOT = Path('/tmp/gogaku-ime-benchmark/libime')
REPO = Path(__file__).resolve().parent.parent
COMMIT = '5be1300ea00e899b3f2c46d1e9f6bca21139cdeb'
FCITX = 'dfb1278cce616a771eb51a99a468bbd69f02613f'  # 5.1.20
ECM = '7dd28cc56c339c3f8fb356f7c53c0e8f61433d81'  # v6.10.0
KENLM = '4cb443e60b7bf2c0ddf3c745378f76cb59e254e5'
ARCHIVES = {
    'dict-20260907.tar.zst': 'fb75a179065e690dfc4559ce1807cbaf4fbe4f0111a5005615be9f435e6b9d76',
    'lm_sc.arpa-20260629.tar.zst': '06808333b9173e5374cf2cb5afc12d08f5625bf9abb536489cac376fc05f2e7f',
}
MANIFEST = {'id': 'I0', 'engine': 'libime', 'version': '1.1.17', 'commit': COMMIT,
            'status': 'preparing', 'command': [], 'build_commands': [], 'sources': [],
            'data': [], 'licenses': [], 'adjustments': [], 'formal_performance_run': False}


def save():
    (ROOT / 'manifest.json').write_text(json.dumps(MANIFEST, ensure_ascii=False, indent=2) + '\n')


def digest(path):
    with Path(path).open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def run(args, name, cwd=None):
    args = [str(arg) for arg in args]
    log = ROOT / (name + '.log')
    record = {'command': args, 'cwd': str(cwd or ROOT), 'log': str(log)}
    MANIFEST['build_commands'].append(record)
    save()
    with log.open('a') as output:
        output.write('\n$ ' + shlex.join(args) + '\n')
        output.flush()
        result = subprocess.run(args, cwd=cwd or ROOT, stdout=output, stderr=subprocess.STDOUT)
    record['exit_code'] = result.returncode
    save()
    if result.returncode:
        raise RuntimeError(f'{name} failed ({result.returncode}); see {log}')


def capture(args):
    return subprocess.check_output([str(arg) for arg in args], text=True).strip()


def checkout(url, directory, commit):
    path = ROOT / directory
    if not (path / '.git').exists():
        run(['git', 'init', path], directory + '-fetch')
        run(['git', '-C', path, 'remote', 'add', 'origin', url], directory + '-fetch')
        run(['git', '-C', path, 'fetch', '--depth', '1', 'origin', commit], directory + '-fetch')
        run(['git', '-C', path, 'checkout', '--detach', commit], directory + '-fetch')
    actual = capture(['git', '-C', path, 'rev-parse', 'HEAD'])
    if actual != commit or capture(['git', '-C', path, 'status', '--porcelain', '--untracked-files=no']):
        raise RuntimeError(f'{path}: expected clean {commit}, got {actual}')
    MANIFEST['sources'].append({'url': url, 'commit': actual, 'path': str(path)})
    return path


def license_file(path, spdx, component):
    # 先实际读取声明/许可，再记录具体文件和哈希；上游文本只保留在 tmp。
    text = path.read_text(errors='replace')
    if not text.strip():
        raise RuntimeError(f'empty license evidence: {path}')
    MANIFEST['licenses'].append({'component': component, 'spdx': spdx,
                                 'path': str(path), 'sha256': digest(path)})
    return text


def download_data(source):
    reuse = source / 'REUSE.toml'
    annotations = tomllib.loads(license_file(reuse, 'LGPL-2.1-or-later', 'libime data declarations'))
    build = license_file(source / 'data/CMakeLists.txt', 'LGPL-2.1-or-later', 'data filenames and expected SHA256')
    for name, expected in ARCHIVES.items():
        if name not in build or expected not in build:
            raise RuntimeError('fixed source data declaration differs from script')
        kind = 'dict-' if name.startswith('dict-') else 'lm_sc.'
        annotation = next(item for item in annotations['annotations'] if kind in item['path'])
        if annotation['SPDX-License-Identifier'] != 'LGPL-2.1-or-later':
            raise RuntimeError('unexpected data license')
        url = 'https://download.fcitx-im.org/data/' + name
        target = ROOT / name
        entry = {'filename': name, 'source': url, 'expected_sha256': expected,
                 'license': annotation['SPDX-License-Identifier'],
                 'copyright': annotation['SPDX-FileCopyrightText'], 'license_evidence': str(reuse)}
        MANIFEST['data'].append(entry)
        save()
        if not target.exists():
            # 不用替代版本或镜像。失败保留 URL、错误与不完整下载供核查。
            partial = target.with_suffix(target.suffix + '.partial')
            try:
                with urllib.request.urlopen(url, timeout=60) as response, partial.open('wb') as output:
                    while chunk := response.read(1024 * 1024):
                        output.write(chunk)
                partial.rename(target)
            except Exception as error:
                entry['error'] = str(error)
                save()
                raise
        entry['actual_sha256'] = digest(target)
        if entry['actual_sha256'] != expected:
            raise RuntimeError(f'SHA256 mismatch: {target}')
    data = ROOT / 'data'
    data.mkdir(exist_ok=True)
    for archive, names in [('dict-20260907.tar.zst', ['dict_sc.txt', 'dict_extb.txt']),
                           ('lm_sc.arpa-20260629.tar.zst', ['lm_sc.arpa'])]:
        if not all((data / name).exists() for name in names):
            run(['tar', '--zstd', '-xf', ROOT / archive, '-C', data, *names], 'data-extract')
    return data


def check_profile(worker):
    table = json.loads(capture([worker, '--dump-profile']))
    spec = importlib.util.spec_from_file_location('frozen_xiaohe_generator', REPO / 'probes/prepare-input-engine-cases.py')
    generator = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(generator)
    syllables = {s for scenario in generator.SCENARIOS for s in scenario[3].split()}
    syllables.update(generator.ZERO)
    syllables.update(['xia', 'xiang'])
    checks = [{'pinyin': s, 'keys': generator.encode_syllable(s),
               'libime_syllables': table.get(generator.encode_syllable(s), [])} for s in sorted(syllables)]
    mismatches = [entry for entry in checks if entry['pinyin'] not in entry['libime_syllables']]
    report = {'generator_sha256': digest(REPO / 'probes/prepare-input-engine-cases.py'),
              'checks': checks, 'mismatches': mismatches}
    (ROOT / 'profile-check.json').write_text(json.dumps(report, ensure_ascii=False, indent=2) + '\n')
    MANIFEST['profile_check'] = {'path': str(ROOT / 'profile-check.json'),
                                 'syllables_checked': len(checks), 'mismatches': mismatches}
    if mismatches:
        raise RuntimeError('Xiaohe mapping differs; see profile-check.json (targets unchanged)')


def smoke(command):
    transcript = []
    with (ROOT / 'smoke.stderr.log').open('w') as errors:
        process = subprocess.Popen(command, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=errors, text=True)
        try:
            ready = json.loads(process.stdout.readline())
            assert ready['ready'] is True
            transcript.append({'ready': ready})

            def request(value):
                process.stdin.write(json.dumps(value) + '\n')
                process.stdin.flush()
                response = json.loads(process.stdout.readline())
                transcript.append({'request': value, 'response': response})
                required = {'ok', 'handled', 'preedit', 'raw_input', 'candidates', 'commit', 'composing',
                            'process_ns', 'collect_ns', 'total_ns'}
                assert required <= response.keys(), response
                assert len(response['candidates']) <= 10
                assert all(type(response[k]) is int and response[k] >= 0 for k in ['process_ns', 'collect_ns', 'total_ns'])
                assert response['total_ns'] == response['process_ns'] + response['collect_ns']
                return response

            def type_keys(keys):
                request({'op': 'reset'})
                for c in keys:
                    result = request({'op': 'key', 'key': ord(c)})
                    assert result['ok'] and result['handled']
                assert result['raw_input'] == keys
                return result

            examples = []
            for keys, target in [('nihc', '你好'), ('kdhv', '开会'), ('woxlxtykyu', '我想学英语')]:
                result = type_keys(keys)
                assert target in result['candidates'], result
                examples.append({'keys': keys, 'candidates': result['candidates']})
                committed = request({'op': 'select', 'index': result['candidates'].index(target)})
                assert committed['commit'] == target and not committed['composing'] and not committed['raw_input']
                assert request({'op': 'peek'})['commit'] == ''
            first = type_keys('nihc')
            # 真实选择短候选，验证不能提前 commit，也不能丢失已选汉字。
            assert '你' in first['candidates'], first
            partial = request({'op': 'select', 'index': first['candidates'].index('你')})
            assert partial['commit'] == '' and partial['raw_input'] == 'hc' and partial['composing']
            assert partial['preedit'].startswith('你') and '好' in partial['candidates']
            full = request({'op': 'key', 'key': 32})
            assert full['commit'] == '你好' and not full['composing']
            assert type_keys('nihc')['candidates'] == first['candidates']
            deleted = request({'op': 'key', 'key': 8})
            assert deleted['raw_input'] == 'nih'
            cancelled = request({'op': 'key', 'key': 27})
            assert cancelled['raw_input'] == '' and not cancelled['composing']
            assert not request({'op': 'select', 'index': 0})['ok']
            assert not request({'op': 'select', 'index': -1})['ok']
            assert not request({'op': 'key', 'key': 'n'})['ok']
            assert not request({'op': 'key', 'key': 999})['ok']
            assert not request({'op': 'unknown'})['ok']
            # 完整 JSON 解码检查及无效输入不能破坏现有 composition。
            for bad in ['{', 'null', '{} {}', '{"op":"peek"} trailing']:
                process.stdin.write(bad + '\n')
                process.stdin.flush()
                response = json.loads(process.stdout.readline())
                transcript.append({'invalid_request': bad, 'response': response})
                assert response['ok'] is False
            typed = type_keys("ni'hc")
            assert typed['candidates'][0] == '你好'
            request({'op': 'reset'})
            assert request({'op': 'peek'})['raw_input'] == ''
            process.stdin.write('{"op":"quit"}\n')
            process.stdin.flush()
            assert json.loads(process.stdout.readline()) == {'ok': True, 'quit': True}
            assert process.wait(timeout=10) == 0
            MANIFEST['smoke'] = {'passed': True, 'examples': examples, 'transcript': str(ROOT / 'smoke.json')}
        finally:
            if process.poll() is None:
                process.kill()
                process.wait()
            (ROOT / 'smoke.json').write_text(json.dumps(transcript, ensure_ascii=False, indent=2) + '\n')


def patch_kenlm_cxx20(source):
    """vendored kenlm 用 std::binary_function（C++17 移除；MacOSX26.5 SDK 的 libc++
    彻底删除残留），libime 以 -std=c++20 编译时 search_trie.cc 等报
    "no template named 'binary_function'"。注入兼容基类并替换 5 个文件的引用。
    幂等：已替换（kenlm_compat 出现）的文件跳过。"""
    kenlm = source / 'src/libime/core/kenlm'
    compat = kenlm / 'util' / 'binary_function_compat.hh'
    if not compat.exists():
        compat.write_text(
            '#pragma once\n'
            '// Gogaku 构建兼容层：kenlm vendored 代码引用的 std::binary_function 在\n'
            '// C++17 起移除、MacOSX26.5 SDK libc++ 删除残留；此基类提供相同成员 typedefs。\n'
            '#ifndef KENLM_BINARY_FUNCTION_COMPAT_HH\n'
            '#define KENLM_BINARY_FUNCTION_COMPAT_HH\n'
            'namespace kenlm_compat {\n'
            'template <class A, class B, class R> struct binary_function {\n'
            '    typedef A first_argument_type;\n'
            '    typedef B second_argument_type;\n'
            '    typedef R result_type;\n'
            '};\n'
            '}\n'
            '#endif\n', encoding='utf-8')
    jobs = [('lm/trie_sort.hh', '#include "util/binary_function_compat.hh"'),
            ('util/sized_iterator.hh', '#include "binary_function_compat.hh"'),
            ('util/stream/sort_test.cc', '#include "../binary_function_compat.hh"'),
            ('util/stream/sort.hh', '#include "binary_function_compat.hh"'),
            ('util/joint_sort.hh', '#include "binary_function_compat.hh"')]
    for rel, include in jobs:
        path = kenlm / rel
        text = path.read_text(encoding='utf-8')
        if 'kenlm_compat::binary_function' in text or 'std::binary_function' not in text:
            continue
        text = text.replace('std::binary_function', 'kenlm_compat::binary_function')
        anchor = text.find('#include')
        if anchor == -1:
            text = include + '\n' + text
        else:
            line_end = text.find('\n', anchor)
            text = text[:line_end + 1] + include + '\n' + text[line_end + 1:]
        path.write_text(text, encoding='utf-8')
        print(f'kenlm c++20 兼容补丁: {rel}')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--jobs', type=int, default=2)
    parser.add_argument('--check-only', action='store_true', help='只核对已构建 worker 的映射及协议')
    args = parser.parse_args()
    ROOT.mkdir(parents=True, exist_ok=True)
    if platform.system() != 'Darwin' or platform.machine() != 'x86_64':
        raise RuntimeError('this preparation is pinned to Intel macOS x86_64')
    MANIFEST['platform'] = platform.platform()
    MANIFEST['compiler'] = capture(['clang++', '--version'])
    MANIFEST['adjustments'] = [
        'Only isolated Fcitx5Utils target and its subdirectory are built/installed; no input method registration.',
        'Fcitx5Utils needs -fexperimental-library for Apple libc++ osyncstream; initial failure log retained.',
        'libime/kenlm needs -D_LIBCPP_ENABLE_CXX17_REMOVED_UNARY_BINARY_FUNCTION for clang 21 libc++ (std::binary_function removed); pinned kenlm trie_sort.hh still derives from it.',
        'libime ENABLE_DATA=OFF avoids unrelated table downloads; build only pinyin/core and two data tools.',
        'Factory data converted using exact upstream commands (-s -a 22 -q 4 trie); no data substitution.',
        'API defaults retained except Xiaohe/useShuangpin/Pinyin preedit; no frontend fuzzy/correction settings added.',
        'No user dict/history is loaded or saved; learn is never called; no personal paths consulted.',
        'Only 10 candidates copied in engine order; partial selections remain composing until fully selected.',
        'All smoke timing is correctness evidence only; no formal performance sampling.',
    ]
    MANIFEST['initial_build_failure'] = {
        'component': 'Fcitx5Utils 5.1.20 with default AppleClang/libc++ flags',
        'reason': "no type named 'osyncstream' in namespace 'std'",
        'log': str(ROOT / 'fcitx-build.log'),
        'resolution': 'reconfigure only isolated Fcitx5Utils with -DCMAKE_CXX_FLAGS=-fexperimental-library',
        'upstream_source_patches': [],
    }
    command = [str(ROOT / 'worker'), str(ROOT / 'data/sc.dict'), str(ROOT / 'data/zh_CN.lm')]
    if not args.check_only:
        source = checkout('https://github.com/fcitx/libime.git', 'source', COMMIT)
        license_file(source / 'LICENSES/LGPL-2.1-or-later.txt', 'LGPL-2.1-or-later', 'libime source and factory data')
        data = download_data(source)
        run(['git', '-C', source, 'submodule', 'update', '--init', '--depth', '1'], 'kenlm-fetch')
        kenlm = source / 'src/libime/core/kenlm'
        assert capture(['git', '-C', kenlm, 'rev-parse', 'HEAD']) == KENLM
        MANIFEST['sources'].append({'url': 'https://github.com/kpu/kenlm.git', 'commit': KENLM, 'path': str(kenlm)})
        for name in ['COPYING', 'COPYING.3', 'COPYING.LESSER.3']:
            license_file(kenlm / name, 'LGPL-2.1-or-later and per-file notices', 'bundled kenlm')
        # KenLM 的非 LGPL 辅助文件保留各文件内许可，不把它们一概标成 LGPL。
        for name in ['util/double-conversion/LICENSE', 'util/string_piece.hh', 'util/murmur_hash.cc',
                     'util/integer_to_string.cc', 'util/getopt.c']:
            path = kenlm / name
            if path.exists():
                license_file(path, 'see retained per-file license text', 'kenlm auxiliary files')
        ecm = checkout('https://github.com/KDE/extra-cmake-modules.git', 'ecm-source', ECM)
        license_file(ecm / 'COPYING-CMAKE-SCRIPTS', 'BSD-3-Clause', 'extra-cmake-modules')
        fcitx = checkout('https://github.com/fcitx/fcitx5.git', 'fcitx5-source', FCITX)
        license_file(fcitx / 'LICENSES/LGPL-2.1-or-later.txt', 'LGPL-2.1-or-later', 'Fcitx5Utils')
        license_file(fcitx / 'LICENSES/Unicode-DFS-2016.txt', 'Unicode-DFS-2016', 'Fcitx5Utils Unicode data')
        prefix = ROOT / 'prefix'
        brew = capture(['brew', '--prefix'])
        MANIFEST['brew_read_only'] = capture(['brew', 'list', '--versions', 'boost', 'fmt', 'zstd', 'json-c', 'gettext', 'cmake', 'ninja'])
        brew_info = json.loads(capture(['brew', 'info', '--json=v2', '--installed', 'boost', 'zstd', 'json-c', 'gettext', 'cmake', 'ninja']))
        MANIFEST['brew_dependencies'] = [
            {'name': formula['name'], 'license': formula.get('license'),
             'source': formula.get('urls'), 'installed': formula.get('installed'),
             'linked_keg': formula.get('linked_keg')}
            for formula in brew_info['formulae']
            if formula['name'] in {'boost', 'zstd', 'json-c', 'gettext', 'cmake', 'ninja'}
        ]
        run(['cmake', '-S', ecm, '-B', ROOT / 'ecm-build', '-G', 'Ninja',
             f'-DCMAKE_INSTALL_PREFIX={prefix}', '-DBUILD_TESTING=OFF', '-DBUILD_DOC=OFF'], 'ecm-configure')
        run(['cmake', '--install', ROOT / 'ecm-build'], 'ecm-install')
        options = ['ENABLE_TEST', 'ENABLE_TESTING_ADDONS', 'ENABLE_X11', 'ENABLE_WAYLAND', 'ENABLE_DBUS',
                   'ENABLE_ENCHANT', 'ENABLE_SERVER', 'ENABLE_KEYBOARD', 'ENABLE_EMOJI', 'ENABLE_LIBUUID',
                   'BUILD_SPELL_DICT', 'ENABLE_XDGAUTOSTART']
        run(['cmake', '-S', fcitx, '-B', ROOT / 'fcitx5-build', '-G', 'Ninja', '-DCMAKE_BUILD_TYPE=Release',
             f'-DCMAKE_INSTALL_PREFIX={prefix}', f'-DCMAKE_PREFIX_PATH={prefix};{brew}/opt/gettext',
             '-DCMAKE_CXX_FLAGS=-fexperimental-library', '-DEVENT_LOOP_BACKEND=none',
             *['-D' + option + '=OFF' for option in options]], 'fcitx-configure-experimental')
        run(['cmake', '--build', ROOT / 'fcitx5-build', '--target', 'Fcitx5Utils', '-j', args.jobs], 'fcitx-build-experimental')
        run(['cmake', '--install', ROOT / 'fcitx5-build/src/lib/fcitx-utils'], 'fcitx-install')
        run(['cmake', '-S', source, '-B', ROOT / 'build', '-G', 'Ninja', '-DCMAKE_BUILD_TYPE=Release',
             f'-DCMAKE_INSTALL_PREFIX={prefix}', f'-DCMAKE_PREFIX_PATH={prefix}', '-DENABLE_TEST=OFF',
             '-DENABLE_DATA=OFF', '-DENABLE_DOC=OFF', '-DENABLE_TOOLS=ON',
             # clang 21 / macOS 26.5 SDK 的 libc++ 默认移除了 std::binary_function
             # （pinned kenlm trie_sort.hh 仍依赖）；用 libc++ 官方兼容开关保留。
             '-DCMAKE_CXX_FLAGS=-D_LIBCPP_ENABLE_CXX17_REMOVED_UNARY_BINARY_FUNCTION'], 'libime-configure')
        run(['cmake', '--build', ROOT / 'build', '--target', 'IMEPinyin', 'libime_pinyindict',
             'libime_slm_build_binary', '-j', args.jobs], 'libime-build')
        if not (data / 'sc.dict').exists():
            run([ROOT / 'build/bin/libime_pinyindict', data / 'dict_sc.txt', data / 'sc.dict'], 'dict-convert')
        if not (data / 'zh_CN.lm').exists():
            run([ROOT / 'build/bin/libime_slm_build_binary', '-s', '-a', '22', '-q', '4', 'trie',
                 data / 'lm_sc.arpa', data / 'zh_CN.lm'], 'lm-convert')
        json_flags = shlex.split(capture(['pkg-config', '--cflags', '--libs', 'json-c']))
        run(['clang++', '-O3', '-DNDEBUG', '-std=c++20', '-Wall', '-Wextra',
             '-I' + str(source / 'src'), '-I' + str(ROOT / 'build/src'),
             '-I' + str(prefix / 'include/Fcitx5/Utils'), '-I' + brew + '/opt/boost/include',
             REPO / 'probes/libime-input-worker.cpp', '-L' + str(ROOT / 'build/bin'),
             '-L' + str(prefix / 'lib'), '-lIMEPinyin', '-lIMECore', '-lFcitx5Utils',
             '-Wl,-rpath,' + str(ROOT / 'build/bin'), '-Wl,-rpath,' + str(prefix / 'lib'),
             *json_flags, '-o', ROOT / 'worker'], 'worker-build')
    else:
        if (ROOT / 'manifest.json').exists():
            MANIFEST.update(json.loads((ROOT / 'manifest.json').read_text()))
    MANIFEST['command'] = command
    MANIFEST['worker_source_sha256'] = digest(REPO / 'probes/libime-input-worker.cpp')
    MANIFEST['artifacts'] = [{'path': str(path), 'sha256': digest(path), 'bytes': path.stat().st_size}
                             for path in [ROOT / 'worker', ROOT / 'data/sc.dict', ROOT / 'data/zh_CN.lm']]
    MANIFEST['linked_libraries'] = capture(['otool', '-L', ROOT / 'worker'])
    check_profile(ROOT / 'worker')
    smoke(command)
    MANIFEST['status'] = 'ready'
    save()
    print(json.dumps({'id': 'I0', 'command': command, 'manifest': str(ROOT / 'manifest.json')}, ensure_ascii=False))


if __name__ == '__main__':
    try:
        main()
    except Exception as error:
        MANIFEST['status'] = 'failed'
        MANIFEST['error'] = str(error)
        if ROOT.exists():
            save()
        print(str(error), file=sys.stderr)
        sys.exit(1)
