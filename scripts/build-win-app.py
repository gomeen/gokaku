#!/usr/bin/env python3
"""验证已构建 Windows PE 依赖闭包，组装 Inno Setup 输入并可调用 ISCC。

只读取产物，不构建或运行 Gogaku。默认输入 .build/win-app/<channel>/bin/{x64,x86}；
TSF 两种架构都连接 x64 代理，只有 x64 需要核心 DLL。--self-test 使用临时 PE
夹具，不能替代 Windows 安装/运行验证。版本唯一来源为根 version.json。
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import platform
import re
import shutil
import stat
import struct
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
from _gogaku_delivery import (DeliveryError, package_receipt_path, source_fingerprint,
                              validate_compile_receipt, write_package_receipt)
VERSION_FILE = ROOT / 'version.json'
ISS_TEMPLATE = ROOT / 'windows/packaging/gogaku.iss.in'
DATA_FILES = ['sc.dict', 'zh_CN.lm', 'english-words.txt', 'gloss.tsv']
APP_IDS = {
    'stable': '{{0F3E6E4A-6D7B-4C1E-9B2A-5C8D7E1F3A21}',
    'dev': '{{7B2D9C4E-1A3F-4E6B-8C5D-2F7A9B1C3E42}',
}
TSF_CLSIDS = {
    'stable': '{A3C5D7E9-1B2F-4A6C-8E0D-2F4B6A8C0E12}',
    'dev': '{A3C5D7E9-1B2F-4A6C-8E0D-2F4B6A8C0E13}',
}
# Windows 11 自带 DLL；VC++/MinGW runtime 不在豁免中，必须随架构闭包提供。
SYSTEM_DLLS = set(('advapi32 avrt bcrypt bcryptprimitives cabinet cfgmgr32 comctl32 '
                  'comdlg32 crypt32 cryptbase cryptsp d2d1 d3d11 dcomp dnsapi dwmapi '
                  'dwrite dxgi gdi32 gdiplus imm32 iphlpapi kernel32 kernelbase msctf '
                  'msimg32 msvcrt netapi32 ntdll normaliz ole32 oleacc oleaut32 powrprof '
                  'propsys psapi rpcrt4 rstrtmgr secur32 setupapi shell32 shcore shlwapi '
                  'sspicli ucrtbase user32 userenv usp10 uxtheme version windowscodecs '
                  'winhttp wininet winmm winspool.drv wintrust wldap32 ws2_32 wtsapi32').split())
SYSTEM_DLLS = {name if '.' in name else name + '.dll' for name in SYSTEM_DLLS}


class InputError(ValueError):
    pass


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open('rb') as handle:
        for chunk in iter(lambda: handle.read(1 << 20), b''):
            digest.update(chunk)
    return digest.hexdigest()


def git_identity(root=ROOT):
    def git(*args):
        return subprocess.check_output(['git', '-C', str(root), *args], text=True).strip()
    try:
        return {'commit': git('rev-parse', 'HEAD'),
                'dirty': bool(git('status', '--porcelain', '--untracked-files=no'))}
    except (OSError, subprocess.CalledProcessError) as error:
        raise InputError(f'无法读取 Git 构建身份：{error}') from error


def load_meta(version=None, build=None, channel='stable', *, version_file=VERSION_FILE,
              git=None):
    try:
        meta = json.loads(version_file.read_text(encoding='utf-8'))
        full, number = meta['version'], meta['buildNumber']
        pattern = r'(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(?:-(dev|rc)\.(0|[1-9][0-9]*))?'
        match = re.fullmatch(pattern, full) if isinstance(full, str) else None
        if not match or type(number) is not int or not 1 <= number <= 65535:
            raise ValueError('版本须为 SemVer dev.N/rc.N/定版，构建号须为 1–65535 整数')
        if any(int(match[i]) > 65535 for i in (1, 2, 3)):
            raise ValueError('Windows 版本数字段不能超过 65535')
    except (OSError, ValueError, KeyError, TypeError) as error:
        raise InputError(f'无法读取合法 version.json：{error}') from error
    if (version is not None and version != full) or (build is not None and build != number):
        raise InputError('--version/--build 不得覆盖根 version.json；兼容参数只能传相同值')
    if channel == 'stable' and '-' in full:
        raise InputError(f'stable 通道只接受正式版本：{full}')
    git = git if git is not None else git_identity()
    phase = match[4] or 'final'
    if phase != 'dev' and git['dirty']:
        raise InputError(f'{phase} 构建要求已跟踪文件干净；请提交修改后构建')
    return full, number, phase, git


def pe_info(path: Path):
    """只用标准库解析 PE/COFF、普通与 delay import；截断/坏 RVA 一律失败。"""
    try:
        data = path.read_bytes()
        def unpack(fmt, offset):
            size = struct.calcsize(fmt)
            if offset < 0 or offset + size > len(data):
                raise ValueError('PE 结构截断')
            return struct.unpack_from(fmt, data, offset)
        if data[:2] != b'MZ':
            raise ValueError('缺少 MZ 标记（非 PE）')
        pe, = unpack('<I', 0x3c)
        if data[pe:pe + 4] != b'PE\0\0':
            raise ValueError('缺少 PE 标记')
        machine, count, _, _, _, optional_size, flags = unpack('<HHIIIHH', pe + 4)
        optional = pe + 24
        magic, = unpack('<H', optional)
        arch = {0x8664: 'x64', 0x14c: 'x86'}.get(machine)
        minimum = 112 if arch == 'x64' else 96
        if not arch or magic != (0x20b if arch == 'x64' else 0x10b):
            raise ValueError(f'不支持/不匹配的 PE Machine={machine:#x}, Magic={magic:#x}')
        if not flags & 2 or not 1 <= count <= 96 or optional_size < minimum:
            raise ValueError('不是可执行 PE 或节表/可选头非法')
        section_table = optional + optional_size
        if section_table + count * 40 > len(data):
            raise ValueError('节表截断')
        header_size, = unpack('<I', optional + 60)
        if not section_table + count * 40 <= header_size <= len(data):
            raise ValueError('SizeOfHeaders 非法')
        sections = []
        for i in range(count):
            virtual_size, rva, raw_size, raw = unpack('<IIII', section_table + i * 40 + 8)
            if raw_size and (raw < header_size or raw + raw_size > len(data)):
                raise ValueError('节数据截断或覆盖文件头')
            sections.append((rva, virtual_size, raw, raw_size))
        if not any(section[3] for section in sections):
            raise ValueError('PE 没有文件节数据')
        def offset(rva, size=1):
            if 0 <= rva < header_size and rva + size <= header_size:
                return rva
            for start, _, raw, raw_size in sections:
                if start <= rva and rva + size <= start + raw_size:
                    return raw + rva - start
            raise ValueError(f'无法映射 PE RVA {rva:#x}')
        entry, = unpack('<I', optional + 16)
        if entry:
            offset(entry)
        directories, = unpack('<I', optional + minimum - 4)
        if directories > (optional_size - minimum) // 8:
            raise ValueError('数据目录越过可选头')
        image_base, = unpack('<Q' if arch == 'x64' else '<I', optional + (24 if arch == 'x64' else 28))
        imports = set()
        for index, stride in ((1, 20), (13, 32)):
            if directories <= index:
                continue
            rva, size = unpack('<II', optional + minimum + index * 8)
            if not rva and not size:
                continue
            if not rva or size < stride:
                raise ValueError('导入表数据目录非法')
            terminated = False
            for pos in range(0, size - stride + 1, stride):
                descriptor = unpack('<' + 'I' * (stride // 4), offset(rva + pos, stride))
                if not any(descriptor):
                    terminated = True
                    break
                name_rva = descriptor[3] if index == 1 else descriptor[1]
                if index == 13 and not descriptor[0] & 1:
                    name_rva -= image_base
                name = bytearray()
                for n in range(260):
                    value = data[offset(name_rva + n)]
                    if not value:
                        break
                    name.append(value)
                else:
                    raise ValueError('导入 DLL 名称未终止')
                dll = name.decode('ascii').lower()
                if not re.fullmatch(r'[a-z0-9_.+\-]+\.(dll|drv)', dll):
                    raise ValueError(f'非法导入名称：{dll!r}')
                imports.add(dll)
            if not terminated:
                raise ValueError('导入描述符表未终止')
        return {'arch': arch, 'dll': bool(flags & 0x2000), 'imports': sorted(imports),
                'sha256': hashlib.sha256(data).hexdigest(), 'bytes': len(data)}
    except (OSError, ValueError, struct.error) as error:
        raise InputError(f'{path}: {error}') from error


def is_system(dll):
    return dll in SYSTEM_DLLS or dll.startswith(('api-ms-win-', 'ext-ms-win-'))


def binary_plan(args):
    """按架构解析根产物及其闭包，不扫描 PATH 或另一架构目录。"""
    base = Path(args.bin_dir or ROOT / f'.build/win-app/{args.channel}/bin')
    legacy = {
        'tsf_x64': ROOT / '.build/win-tsf/x64/Release/GogakuTsf.dll',
        'tsf_x86': ROOT / '.build/win-tsf/x86/Release/GogakuTsf.dll',
        'agent': ROOT / '.build/win-agent/Release/GogakuAgent.exe',
        'settings': ROOT / '.build/win-settings/Release/GogakuSettings.exe',
    }
    plans, evidence = {}, {}
    for arch in ('x64', 'x86'):
        core_arg = args.core_dir if arch == 'x64' else args.core_dir_x86
        core_dir = Path(core_arg or ROOT / ('.build/win-cross/clang64/bin' if arch == 'x64'
                                            else '.build/win-cross/clang32/bin'))
        entries = [('GogakuTsf.dll', f'tsf_{arch}')]
        if arch == 'x64':
            entries += [('GogakuAgent.exe', 'agent'), ('GogakuSettings.exe', 'settings'),
                        ('libgogaku_core.dll', None)]
        roots = {}
        for name, option in entries:
            explicit = getattr(args, option) if option else None
            preferred = base / arch / name
            if explicit:
                path = Path(explicit)
            elif option is None and core_arg:
                path = core_dir / name
            elif args.bin_dir or preferred.is_file():
                path = preferred
            else:
                path = legacy[option] if option else core_dir / name
            if not path.is_file():
                raise InputError(f'缺少 {arch}/{name}：{path}')
            roots[name.lower()] = (name, path.resolve())
        search_dirs = list(dict.fromkeys([path.parent for _, path in roots.values()] +
                                        [base / arch, core_dir]))
        candidates = {}
        for folder in search_dirs:
            if not folder.is_dir():
                continue
            names = {}
            for path in sorted(folder.iterdir()):
                if path.is_file() and path.suffix.lower() == '.dll':
                    key = path.name.lower()
                    if key in names:
                        raise InputError(f'Windows 文件名大小写冲突：{folder / key}')
                    names[key] = path
                    candidates.setdefault(key, path.resolve())
        pending = list(roots.values())
        copied, infos = {}, {}
        while pending:
            name, path = pending.pop()
            key = name.lower()
            if key in infos:
                if copied[key][1] != path and sha256(copied[key][1]) != sha256(path):
                    raise InputError(f'{arch} DLL 来源冲突：{name}')
                continue
            info = pe_info(path)
            if info['arch'] != arch:
                raise InputError(f'{path}: 架构为 {info["arch"]}，需要 {arch}')
            if info['dll'] != name.lower().endswith('.dll'):
                raise InputError(f'{path}: PE DLL/EXE 类型与目标名称不符')
            copied[key] = (name, path)
            infos[key] = info
            for dll in info['imports']:
                if is_system(dll):
                    continue
                if dll in roots:
                    dependency = roots[dll]
                elif dll in candidates:
                    dependency = (candidates[dll].name, candidates[dll])
                else:
                    raise InputError(f'{arch}/{name} 缺少非系统依赖 {dll}（仅搜索本架构目录）')
                pending.append(dependency)
        # 核心由 x64 agent 动态加载；TSF 自身及间接依赖均不能加载核心。
        def reaches_core(name, seen):
            if name == 'libgogaku_core.dll':
                return True
            if name in seen:
                return False
            seen.add(name)
            return any(reaches_core(item, seen) for item in infos[name]['imports'] if item in infos)
        if reaches_core('gogakutsf.dll', set()):
            raise InputError(f'{arch} TSF 仍直接或间接依赖核心；应通过私有管道连接 x64 代理')
        plans[arch] = [copied[key] for key in sorted(copied)]
        evidence[arch] = {copied[key][0]: infos[key] for key in sorted(infos)}
    return plans, evidence


def resource_plan(args):
    data = Path(args.data_dir)
    result = [(data / name, Path('data') / name) for name in DATA_FILES]
    resources = Path(args.resources_dir)
    for name in ('english-wordlist-sources.json', 'gloss-sources.json'):
        result.append((resources / name, Path('data') / name))
    result.append((resources / 'update/config.json', Path('resources/update/windows.json')))
    # 仅从指定许可目录复制；保留目录结构，避免同名 LICENSE/COPYING 互相覆盖。
    license_dirs = [Path(value) for value in (args.license_dir or [ROOT / 'shared/licenses'])]
    license_dirs += [resources / 'licenses']
    for i, folder in enumerate(license_dirs):
        if not folder.is_dir() or not any(p.is_file() for p in folder.rglob('*')):
            raise InputError(f'许可目录不存在或为空：{folder}')
        result += [(p, Path('licenses') / f'{i:02d}-{folder.name}' / p.relative_to(folder))
                   for p in sorted(folder.rglob('*')) if p.is_file()]
    # 出厂资源锁和仓库中的派生数据来源清单共同约束缓存内容。
    lock = json.loads(Path(args.data_lock).read_text(encoding='utf-8'))
    if set(lock['data']) != {'sc.dict', 'zh_CN.lm'}:
        raise InputError('出厂数据锁必须覆盖 sc.dict 与 zh_CN.lm')
    for name, expected in lock['data'].items():
        if name not in DATA_FILES or sha256(data / name) != expected:
            raise InputError(f'出厂数据哈希不符：{name}')
    for name, manifest in [('english-words.txt', 'english-wordlist-sources.json'),
                           ('gloss.tsv', 'gloss-sources.json')]:
        expected = json.loads((resources / manifest).read_text(encoding='utf-8'))['output_sha256']
        if sha256(data / name) != expected:
            raise InputError(f'来源清单与数据不符：{name}')
    # 对外声明由当前仓库维护，不能沿用暂存目录中的陈旧版本。
    result.append((ROOT / 'docs/third-party.md', Path('licenses/THIRD-PARTY.md')))
    source = Path(args.deps_source_dir)
    required_licenses = {
        'libime/LICENSES/LGPL-2.1-or-later.txt': 'libime/LGPL-2.1-or-later.txt',
        'libime/src/libime/core/kenlm/COPYING': 'kenlm/COPYING',
        'libime/src/libime/core/kenlm/COPYING.3': 'kenlm/COPYING.3',
        'libime/src/libime/core/kenlm/COPYING.LESSER.3': 'kenlm/COPYING.LESSER.3',
        'libime/src/libime/core/kenlm/LICENSE': 'kenlm/LICENSE',
        'fcitx5/LICENSES/LGPL-2.1-or-later.txt': 'fcitx5/LGPL-2.1-or-later.txt',
        'fcitx5/LICENSES/Unicode-DFS-2016.txt': 'fcitx5/Unicode-DFS-2016.txt',
    }
    result += [(source / name, Path('licenses') / target) for name, target in required_licenses.items()]
    windows = Path(args.windows_source_dir)
    for name in ('miniz-LICENSE.txt', 'monocypher-LICENCE.md'):
        result.append((windows / 'third_party' / name, Path('licenses/windows') / name))
    # json.hpp 与共享核心共用一份（shared/third_party），许可文本跟着走。
    result.append((Path(args.third_party_dir) / 'json-LICENSE.MIT',
                   Path('licenses/windows') / 'json-LICENSE.MIT'))
    for path, _ in result:
        if not path.is_file() or not path.stat().st_size:
            raise InputError(f'缺少资源或实际许可文本：{path}')
    return result


def copy_into(source, destination):
    destination.parent.mkdir(parents=True, exist_ok=True)
    # 出厂数据可带 macOS uchg 标志；安装器暂存文件只需要字节，不继承文件标志。
    shutil.copyfile(source, destination)


def remove_generated_stage(folder):
    if hasattr(stat, 'UF_IMMUTABLE'):
        for path in folder.rglob('*'):
            if path.is_file() and path.stat().st_flags & stat.UF_IMMUTABLE:
                os.chflags(path, path.stat().st_flags & ~stat.UF_IMMUTABLE)
    shutil.rmtree(folder)


def inno_path(path):
    value = str(Path(path).resolve())
    # 本地 Wine wrapper 只转换 .iss 参数；模板内路径需显式转换为 Z:。
    return 'Z:' + value.replace('/', '\\') if os.name != 'nt' else value


def stage(args, *, version_file=VERSION_FILE, git=None):
    version, build, phase, git = load_meta(args.version, args.build, args.channel,
                                          version_file=version_file, git=git)
    source = source_fingerprint(ROOT)
    receipts = {arch: validate_compile_receipt(
        Path(args.bin_dir or ROOT / f'.build/win-app/{args.channel}/bin') / arch / 'build-receipt.json',
        Path(args.bin_dir or ROOT / f'.build/win-app/{args.channel}/bin') / arch,
        args.channel, arch, meta={'version': version, 'buildNumber': build}, source=source)
        for arch in ('x64', 'x86')}
    if receipts['x64']['git'] != receipts['x86']['git'] or receipts['x64']['git'] != git:
        raise InputError('两架构 Git 编译身份与当前工作区不一致')
    plans, evidence = binary_plan(args)
    for arch, names in (('x64', ['GogakuTsf.dll', 'GogakuAgent.exe',
                                 'GogakuSettings.exe', 'libgogaku_core.dll']),
                        ('x86', ['GogakuTsf.dll'])):
        for name in names:
            if evidence[arch][name]['sha256'] != receipts[arch]['artifacts'][name]['sha256']:
                raise InputError(f'{arch}/{name} 未来自本轮编译收据；禁止覆盖构建身份')
    resources = resource_plan(args)
    suffix = '-dev' if args.channel == 'dev' else ''
    output_base = f'Gogaku-{version}-b{build}{suffix}-windows-x64-setup'
    out_root = Path(args.out or ROOT / 'dist/gogaku-win').resolve()
    stage_dir = out_root / f'{version}-b{build}{suffix}'
    # 校验完成才替换旧暂存目录；不能删除恰好被指定为输入的目录。
    sources = [p for entries in plans.values() for _, p in entries] + [p.resolve() for p, _ in resources]
    source_hashes = {p.resolve(): sha256(p) for p, _ in resources}
    source_hashes.update({p: evidence[arch][name]['sha256']
                          for arch, entries in plans.items() for name, p in entries})
    if any(stage_dir == p or stage_dir in p.parents for p in sources):
        raise InputError(f'输出目录包含输入文件：{stage_dir}')
    if stage_dir.exists():
        remove_generated_stage(stage_dir)
    for arch, entries in plans.items():
        for name, path in entries:
            destination = stage_dir / 'bin' / arch / name
            copy_into(path, destination)
            if sha256(destination) != source_hashes[path]:
                raise InputError(f'组装期间 PE 输入变化，请待 native 构建结束后重试：{path}')
    for path, relative in resources:
        copy_into(path, stage_dir / relative)
        if sha256(stage_dir / relative) != source_hashes[path.resolve()]:
            raise InputError(f'组装期间资源输入变化：{path}')
    identity = {
        'fullVersion': version, 'buildNumber': build, 'phase': phase, 'channel': args.channel,
        'platform': 'windows', 'arch': 'x86_64', 'builtOn': platform.platform(),
        'git': git, 'gitCommit': git['commit'], 'dirty': git['dirty'],
        'sourceSha256': source, 'compileReceipts': receipts,
        'versionSourceSha256': sha256(version_file), 'peDependencies': evidence,
        'artifacts': {str(p.relative_to(stage_dir)): {'sha256': sha256(p), 'bytes': p.stat().st_size}
                      for p in sorted(stage_dir.rglob('*')) if p.is_file()},
    }
    (stage_dir / 'build-identity.json').write_text(json.dumps(identity, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
    replacements = {
        '@APP_NAME@': 'Gogaku Dev' if args.channel == 'dev' else 'Gogaku',
        '@VERSION@': version, '@BUILD@': str(build), '@CHANNEL@': args.channel,
        '@APP_ID@': APP_IDS[args.channel], '@TSF_CLSID@': TSF_CLSIDS[args.channel],
        '@INSTALL_DIR@': 'GogakuDev' if args.channel == 'dev' else 'Gogaku',
        '@AGENT_RUN_VALUE@': 'GogakuDevAgent' if args.channel == 'dev' else 'GogakuAgent',
        '@OUTPUT_DIR@': inno_path(out_root), '@OUTPUT_BASE@': output_base,
        '@VERSION_QUAD@': version.split('-', 1)[0] + f'.{build}',
        '@APP_MUTEX@': 'GogakuDevSetupMutex' if args.channel == 'dev' else 'GogakuSetupMutex',
        '@STAGE_DIR@': inno_path(stage_dir), '@REPO@': args.repo or 'gogaku/gogaku-releases',
        '@ICON_FILE@': inno_path(ROOT / 'windows/assets/Gogaku.ico'),
    }
    iss = ISS_TEMPLATE.read_text(encoding='utf-8')
    for token, value in replacements.items():
        if any(c in value for c in ('"', '\n', '\r')):
            raise InputError(f'Inno 模板参数含非法字符：{token}')
        iss = iss.replace(token, value)
    if re.search(r'@[A-Z_]+@', iss):
        raise InputError('Inno 模板有未渲染参数')
    iss_path = stage_dir / f'{output_base}.iss'
    iss_path.write_text(iss, encoding='utf-8-sig')
    if args.iscc:
        setup = out_root / f'{output_base}.exe'
        # 防止旧 exe 冒充本轮编译成功。
        setup.unlink(missing_ok=True)
        package_receipt_path(setup).unlink(missing_ok=True)
        setup.with_suffix('.exe.sha256').unlink(missing_ok=True)
        try:
            result = subprocess.run([args.iscc, str(iss_path)], check=False)
        except OSError as error:
            raise InputError(f'无法运行 iscc：{error}') from error
        if result.returncode != 0:
            setup.unlink(missing_ok=True)
            raise InputError(f'iscc 失败（exit={result.returncode}）；安装器未生成')
        if not setup.is_file() or setup.stat().st_size == 0:
            raise InputError(f'iscc 返回成功但未找到有效产物：{setup}')
        changed = [str(path) for path, digest in source_hashes.items()
                   if not path.is_file() or sha256(path) != digest]
        if changed or sha256(version_file) != identity['versionSourceSha256'] or source_fingerprint(ROOT) != source:
            setup.unlink(missing_ok=True)
            raise InputError('Inno 编译期间输入或版本已变化，请重新组装：' + ', '.join(changed))
        write_package_receipt(setup, 'windows', args.channel, identity,
                              stage_dir / 'build-identity.json',
                              [str(p.relative_to(stage_dir)) for p in stage_dir.glob('licenses/**/*') if p.is_file()],
                              root=ROOT)
        digest = sha256(setup)
        setup.with_suffix('.exe.sha256').write_text(f'{digest}  {setup.name}\n', encoding='utf-8')
        print(f'Windows Setup：{setup}\nSHA-256：{digest}')
    else:
        print(f'已暂存并验证安装器输入：{stage_dir}\niss：{iss_path}')
    return stage_dir


def make_parser():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--self-test', action='store_true')
    parser.add_argument('--check', action='store_true')
    parser.add_argument('--channel', choices=['stable', 'dev'], default='stable')
    parser.add_argument('--version', help='兼容参数：必须等于根 version.json')
    parser.add_argument('--build', type=int, help='兼容参数：必须等于根 version.json')
    parser.add_argument('--repo', default=os.environ.get('GOGAKU_UPDATE_REPO', ''))
    parser.add_argument('--bin-dir', help='包含 x64/、x86/ 的预构建输入目录')
    for name in ('core-dir', 'core-dir-x86', 'tsf-x64', 'tsf-x86', 'agent', 'settings'):
        parser.add_argument('--' + name, help='兼容旧的独立产物路径；优先于 --bin-dir')
    parser.add_argument('--data-dir', default=str(ROOT / '.build/win-data'))
    parser.add_argument('--data-lock', default=str(ROOT / 'scripts/windows-setup-dependencies.lock.json'),
                        help='固定的出厂数据 SHA-256 来源锁')
    parser.add_argument('--resources-dir', default=str(ROOT / 'resources'))
    parser.add_argument('--license-dir', action='append', help='额外原生许可目录，可重复；默认 shared/licenses')
    parser.add_argument('--deps-source-dir', default=str(ROOT / '.build/win-cross/static'),
                        help='包含 libime/、fcitx5/ 的实际原生依赖源码许可根目录')
    parser.add_argument('--windows-source-dir', default=str(ROOT / 'windows/GogakuWindows'))
    parser.add_argument('--third-party-dir', default=str(ROOT / 'shared/third_party'))
    parser.add_argument('--out', help='默认 dist/gogaku-win')
    parser.add_argument('--iscc', help='ISCC.exe 或仅编译 Inno 的本机 wrapper')
    return parser


def self_test(iscc=None):
    # 夹具仅在 TemporaryDirectory 中生成；生产路径始终执行相同 PE 校验。
    def fake_pe(path, arch, imports=(), delay=()):
        path.parent.mkdir(parents=True, exist_ok=True)
        data = bytearray(4096)
        data[:2] = b'MZ'
        struct.pack_into('<I', data, 0x3c, 0x80)
        data[0x80:0x84] = b'PE\0\0'
        minimum = 112 if arch == 'x64' else 96
        optional_size = minimum + 16 * 8
        flags = 2 | (0x2000 if path.suffix.lower() == '.dll' else 0)
        struct.pack_into('<HHIIIHH', data, 0x84, 0x8664 if arch == 'x64' else 0x14c,
                         1, 0, 0, 0, optional_size, flags)
        optional = 0x98
        struct.pack_into('<H', data, optional, 0x20b if arch == 'x64' else 0x10b)
        struct.pack_into('<I', data, optional + 60, 512)
        struct.pack_into('<I', data, optional + minimum - 4, 16)
        section = optional + optional_size
        data[section:section + 8] = b'.rdata\0\0'
        struct.pack_into('<IIII', data, section + 8, 3584, 0x1000, 3584, 512)
        for index, names, raw, stride in ((1, imports, 512, 20), (13, delay, 1024, 32)):
            if not names:
                continue
            struct.pack_into('<II', data, optional + minimum + index * 8,
                             raw - 512 + 0x1000, (len(names) + 1) * stride)
            text = raw + (len(names) + 1) * stride
            for i, name in enumerate(names):
                rva = text - 512 + 0x1000
                if index == 1:
                    struct.pack_into('<IIIII', data, raw + i * stride, 0, 0, 0, rva, 0)
                else:
                    struct.pack_into('<IIIIIIII', data, raw + i * stride, 1, rva, 0, 0, 0, 0, 0, 0)
                encoded = name.encode() + b'\0'
                data[text:text + len(encoded)] = encoded
                text += len(encoded)
        path.write_bytes(data)
    with tempfile.TemporaryDirectory(prefix='gogaku-package-test-') as temporary:
        root = Path(temporary)
        args = make_parser().parse_args(['--channel', 'dev', '--bin-dir', str(root / 'bin'),
                                         '--data-dir', str(root / 'data'), '--out', str(root / 'out')])
        for arch in ('x64', 'x86'):
            fake_pe(root / f'bin/{arch}/GogakuTsf.dll', arch, ['KERNEL32.dll', 'USER32.dll'])
        fake_pe(root / 'bin/x64/GogakuAgent.exe', 'x64', ['KERNEL32.dll'])
        fake_pe(root / 'bin/x64/GogakuSettings.exe', 'x64', ['libgogaku_core.dll'])
        fake_pe(root / 'bin/x64/libgogaku_core.dll', 'x64', ['libwinpthread-1.dll'])
        fake_pe(root / 'bin/x64/libwinpthread-1.dll', 'x64', delay=['api-ms-win-core-synch-l1-2-0.dll'])
        for name in DATA_FILES:
            path = root / 'data' / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(b'fixture data')
        # 明确隔离所有资源/许可输入，测试不依赖开发机源码缓存。
        args.resources_dir = str(root / 'resources')
        args.deps_source_dir = str(root / 'deps')
        args.windows_source_dir = str(root / 'windows')
        args.third_party_dir = str(root / 'third_party')
        args.license_dir = [str(root / 'licenses')]
        paths = ['resources/english-wordlist-sources.json', 'resources/gloss-sources.json',
                 'resources/update/config.json', 'resources/licenses/DATA.txt', 'licenses/COPYING',
                 'licenses/THIRD-PARTY.md',
                 'deps/libime/LICENSES/LGPL-2.1-or-later.txt',
                 'deps/fcitx5/LICENSES/LGPL-2.1-or-later.txt', 'deps/fcitx5/LICENSES/Unicode-DFS-2016.txt']
        paths += ['deps/libime/src/libime/core/kenlm/' + name
                  for name in ('COPYING', 'COPYING.3', 'COPYING.LESSER.3', 'LICENSE')]
        paths += ['windows/third_party/' + name for name in
                  ('miniz-LICENSE.txt', 'monocypher-LICENCE.md')]
        paths += ['third_party/json-LICENSE.MIT']
        for relative in paths:
            path = root / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text('fixture resource/license', encoding='utf-8')
        for name, manifest in [('english-words.txt', 'english-wordlist-sources.json'),
                               ('gloss.tsv', 'gloss-sources.json')]:
            (root / 'resources' / manifest).write_text(json.dumps({'output_sha256': sha256(root / 'data' / name)}))
        lock = root / 'data-lock.json'
        lock.write_text(json.dumps({'data': {name: sha256(root / 'data' / name)
                                             for name in ('sc.dict', 'zh_CN.lm')}}))
        args.data_lock = str(lock)
        version_file = root / 'version.json'
        version_file.write_text('{"version":"0.1.1-dev.2","buildNumber":88}')
        git = {'commit': 'a' * 40, 'dirty': True}
        source = source_fingerprint(ROOT)
        for arch, names in [('x64', ['GogakuTsf.dll', 'GogakuAgent.exe', 'GogakuSettings.exe',
                                    'libgogaku_core.dll']), ('x86', ['GogakuTsf.dll'])]:
            folder = root / 'bin' / arch
            (folder / 'build-receipt.json').write_text(json.dumps({
                'schema': 1, 'fullVersion': '0.1.1-dev.2', 'buildNumber': 88,
                'channel': 'dev', 'arch': arch, 'configuration': 'release', 'git': git,
                'sourceSha256': source,
                'artifacts': {name: {'sha256': sha256(folder / name),
                                     'bytes': (folder / name).stat().st_size} for name in names}}))
        args.iscc = iscc
        if iscc:
            print('仅对临时合成 PE 夹具编译 Inno；此测试安装器不用于交付，也不会执行。')
        # 合成安装器的版本来源也留在临时夹具中；不改真实 version.json。
        from unittest.mock import patch
        def fixture_stage():
            with patch('_gogaku_delivery.current_meta', return_value=json.loads(version_file.read_text())):
                return stage(args, version_file=version_file, git=git)
        staged = fixture_stage()
        identity = json.loads((staged / 'build-identity.json').read_text())
        assert identity['dirty'] and identity['gitCommit'] == 'a' * 40
        assert identity['fullVersion'] == '0.1.1-dev.2' and identity['buildNumber'] == 88
        for relative, value in identity['artifacts'].items():
            assert sha256(staged / relative) == value['sha256']
        assert not (staged / 'bin/x86/libgogaku_core.dll').exists()
        assert (staged / 'bin/x64/libwinpthread-1.dll').is_file()
        assert (staged / 'licenses/THIRD-PARTY.md').read_bytes() == (ROOT / 'docs/third-party.md').read_bytes()
        assert (staged / 'resources/update/windows.json').read_bytes() == (root / 'resources/update/config.json').read_bytes()
        if hasattr(stat, 'UF_IMMUTABLE'):
            immutable = staged / 'data/sc.dict'
            os.chflags(immutable, immutable.stat().st_flags | stat.UF_IMMUTABLE)
            assert fixture_stage() == staged
            assert not (immutable.stat().st_flags & stat.UF_IMMUTABLE)
        text = next(staged.glob('*.iss')).read_text(encoding='utf-8-sig')
        assert 'AfterInstall: RegisterComponents' in text
        assert 'DestDir: "{app}\\versions\\{#AppVersion}-b{#AppBuild}-{#AppChannel}\\bin\\x64"' in text
        assert 'DestDir: "{app}\\bin\\x64"' not in text
        assert 'GogakuAgent.exe"; Parameters: "--set-autostart on"' in text
        assert 'Regsvr(Architecture: String; DllPath: String; Unregister: Boolean' in text
        assert '{A3C5D7E9-1B2F-4A6C-8E0D-2F4B6A8C0E13}' in text
        assert '\n[UninstallRun]\n' not in text and '@STAGE_DIR@' not in text
        assert 'Source: "' + inno_path(staged) + '\\*"' not in text
        def rejected(action, message):
            try:
                action()
            except InputError as error:
                assert message in str(error), str(error)
            else:
                raise AssertionError(f'应拒绝：{message}')
        rejected(lambda: load_meta('9.9.9', channel='dev', version_file=version_file, git=git), '不得覆盖')
        rejected(lambda: load_meta(build=89, channel='dev', version_file=version_file, git=git), '不得覆盖')
        for version in ('0.1.1-rc.1', '0.1.1'):
            version_file.write_text(json.dumps({'version': version, 'buildNumber': 88}))
            rejected(lambda: load_meta(channel='dev', version_file=version_file, git=git), '干净')
        runtime = root / 'bin/x64/libwinpthread-1.dll'
        saved = runtime.read_bytes()
        runtime.unlink()
        rejected(lambda: binary_plan(args), '缺少非系统依赖')
        runtime.write_bytes(b'not a PE')
        rejected(lambda: binary_plan(args), '非 PE')
        fake_pe(runtime, 'x86')
        rejected(lambda: binary_plan(args), '架构为 x86')
        runtime.write_bytes(saved[:200])
        rejected(lambda: binary_plan(args), '截断')
        runtime.write_bytes(saved)
        fake_pe(root / 'bin/x64/libgogaku_core.dll', 'x64', delay=['missing-delay.dll'])
        rejected(lambda: binary_plan(args), 'missing-delay.dll')
        fake_pe(root / 'bin/x64/libgogaku_core.dll', 'x64')
        fake_pe(root / 'bin/x86/GogakuTsf.dll', 'x86', ['libgogaku_core.dll'])
        rejected(lambda: binary_plan(args), '缺少非系统依赖')
        fake_pe(root / 'bin/x86/libgogaku_core.dll', 'x86')
        rejected(lambda: binary_plan(args), 'TSF 仍直接或间接依赖核心')
        fake_pe(root / 'bin/x86/GogakuTsf.dll', 'x86')
        (root / 'data/english-words.txt').write_text('wrong non-empty')
        rejected(lambda: resource_plan(args), '来源清单与数据不符')
        (root / 'data/english-words.txt').write_bytes(b'fixture data')
        # 不再被引用的坏 DLL 不应被打包；旧 --core-dir-x86 不要求 x86 核心。
        (root / 'bin/x86/libgogaku_core.dll').write_bytes(b'ignored extra')
        args.core_dir = str(root / 'bin/x64')
        args.core_dir_x86 = str(root / 'empty-x86-core')
        args.tsf_x64 = str(root / 'bin/x64/GogakuTsf.dll')
        args.tsf_x86 = str(root / 'bin/x86/GogakuTsf.dll')
        assert len(binary_plan(args)[0]['x86']) == 1
        (root / 'resources/update/config.json').unlink()
        rejected(lambda: resource_plan(args), '缺少资源')
        args.agent = str(root / 'alternate/GogakuAgent.exe')
        (root / 'resources/update/config.json').write_text('fixture resource/license')
        version_file.write_text('{"version":"0.1.1-dev.2","buildNumber":88}')
        fake_pe(root / 'bin/x64/libgogaku_core.dll', 'x64', ['libwinpthread-1.dll'])
        fake_pe(root / 'bin/x86/GogakuTsf.dll', 'x86', ['KERNEL32.dll', 'USER32.dll'])
        fake_pe(Path(args.agent), 'x64', ['KERNEL32.dll', 'USER32.dll'])
        rejected(lambda: stage(args, version_file=version_file, git=git), '未来自本轮编译收据')
        print('Windows 打包 self-test 通过：架构/导入闭包、delay import、拒绝假 PE/缺依赖、'
              '旧参数、资源许可、identity 哈希、版本单源与 dirty 门禁、Inno 布局。')


def main():
    args = make_parser().parse_args()
    try:
        if args.self_test:
            self_test(args.iscc)
        elif args.check:
            meta = load_meta(args.version, args.build, args.channel)
            source = source_fingerprint(ROOT)
            for arch in ('x64', 'x86'):
                folder = Path(args.bin_dir or ROOT / f'.build/win-app/{args.channel}/bin') / arch
                validate_compile_receipt(folder / 'build-receipt.json', folder, args.channel, arch,
                                         meta={'version': meta[0], 'buildNumber': meta[1]}, source=source)
            plan, evidence = binary_plan(args)
            for arch, names in (('x64', ['GogakuTsf.dll', 'GogakuAgent.exe',
                                         'GogakuSettings.exe', 'libgogaku_core.dll']),
                                ('x86', ['GogakuTsf.dll'])):
                receipt = validate_compile_receipt(
                    Path(args.bin_dir or ROOT / f'.build/win-app/{args.channel}/bin') / arch / 'build-receipt.json',
                    Path(args.bin_dir or ROOT / f'.build/win-app/{args.channel}/bin') / arch,
                    args.channel, arch, meta={'version': meta[0], 'buildNumber': meta[1]}, source=source)
                for name in names:
                    if evidence[arch][name]['sha256'] != receipt['artifacts'][name]['sha256']:
                        raise InputError(f'{arch}/{name} 与编译收据不符')
            resources = resource_plan(args)
            print(f'Windows 输入通过：x64 {len(plan["x64"])} 个 PE，x86 {len(plan["x86"])} 个 PE，'
                  f'{len(resources)} 个资源/许可文件')
        else:
            stage(args)
    except (InputError, DeliveryError, OSError, KeyError, ValueError) as error:
        print(f'Windows 打包失败：{error}', file=sys.stderr)
        raise SystemExit(2) from error


if __name__ == '__main__':
    main()
