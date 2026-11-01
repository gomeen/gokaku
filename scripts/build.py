#!/usr/bin/env python3
"""构建并组装仅依赖系统库/包内库的本机开发版；不注册/切换输入源。

版本来源：仓库根目录 version.json（唯一来源，见 docs/versioning.md）。
- version：完整 SemVer（可带 -dev.N / -rc.N 预发布段）。
- buildNumber：单调递增整数，写入两套应用的 CFBundleVersion。
- CFBundleShortVersionString 只写三段数字；完整版本另存包内 build-identity.json。
- dev 构建允许带未提交修改（dirty=true 记入身份）；rc／定版构建要求工作区干净。
"""
import argparse
import hashlib
import json
import os
import platform
import subprocess
import sys
from pathlib import Path
import plistlib
import re
import shutil

ROOT = Path(__file__).resolve().parent.parent
VERSION_FILE = ROOT / 'version.json'

_SEMVER = re.compile(r'^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)'
                     r'(-(0|[1-9]\d*|dev|rc)\.(0|[1-9]\d*))?$')


def load_version(path: Path = VERSION_FILE) -> dict:
    """读取并校验 version.json；任何非法输入直接报错（不允许带病构建）。"""
    try:
        data = json.loads(path.read_text())
    except FileNotFoundError:
        raise SystemExit(f'缺少版本来源：{path}')
    except json.JSONDecodeError as e:
        raise SystemExit(f'version.json 不是合法 JSON：{e}')
    if not isinstance(data, dict):
        raise SystemExit('version.json 顶层必须是对象')
    extra = set(data) - {'version', 'buildNumber'}
    if extra:
        raise SystemExit(f'version.json 含未知字段：{sorted(extra)}')
    version = data.get('version')
    if not isinstance(version, str) or not _SEMVER.match(version):
        raise SystemExit(f'非法版本号：{version!r}（需要 SemVer 三段数字，'
                         f'预发布段只允许 dev.N／rc.N，如 0.1.0-dev.1）')
    build = data.get('buildNumber')
    if not isinstance(build, int) or isinstance(build, bool) or build < 1:
        raise SystemExit(f'非法构建号：{build!r}（需要正整数）')
    return {'version': version, 'buildNumber': build}


def version_release(version: str) -> str:
    """三段数字部分（CFBundleShortVersionString 只允许数字段）。"""
    return version.split('-', 1)[0]


def version_stage(version: str) -> str:
    """dev（默认）／rc／final（无预发布段）。rc／final 构建要求工作区干净。"""
    if '-' not in version:
        return 'final'
    pre = version.split('-', 1)[1]
    return 'rc' if pre.startswith('rc.') else 'dev'


def git_identity() -> dict:
    def git(*args):
        return subprocess.run(['git', *args], cwd=ROOT, capture_output=True, text=True)
    commit = git('rev-parse', 'HEAD')
    # dirty 只看已跟踪文件的修改：未跟踪的验收产物（verify 报告、日志）不是
    # 源码身份的一部分，否则验证过程自身会产生 dirty。
    status = git('status', '--porcelain', '--untracked-files=no')
    if commit.returncode != 0:
        raise SystemExit('git 不可用或仓库未初始化；构建身份需要提交信息')
    dirty = bool(status.stdout.strip())
    return {'commit': commit.stdout.strip(), 'dirty': dirty}


def require_clean_allowed(stage: str, dirty: bool) -> None:
    if stage in ('rc', 'final') and dirty:
        raise SystemExit(f'{stage} 构建要求源码已提交且工作区干净；'
                         '请先提交或改用 dev 版本号。')


def check_build_number_not_regressing(new: int, baseline: int) -> None:
    if new < baseline:
        raise SystemExit(f'构建号倒退：{new} < 已有 {baseline}；'
                         'buildNumber 必须单调递增（见 docs/versioning.md）。')
if 'DEVELOPER_DIR' not in os.environ and Path('/Applications/Xcode.app/Contents/Developer').is_dir():
    os.environ['DEVELOPER_DIR'] = '/Applications/Xcode.app/Contents/Developer'
CACHE = Path(os.environ.get('GOGAKU_DEPS', Path.home() / 'Library/Caches/Gogaku/libime-1.1.17'))
# 构建根：默认 .build；verify.py 干净构建用 GOGAKU_BUILD_ROOT 指到全新目录。
BUILD_ROOT = Path(os.environ.get('GOGAKU_BUILD_ROOT', ROOT / '.build'))
DIST = ROOT / 'dist'

def run(args):
    subprocess.run([str(a) for a in args], cwd=ROOT, check=True)

def output(args):
    return subprocess.check_output([str(a) for a in args], cwd=ROOT, text=True)

def digest(path):
    with path.open('rb') as f:
        return hashlib.file_digest(f, 'sha256').hexdigest()

def libraries(path):
    lines = output(['otool', '-L', path]).splitlines()[1:]
    return [line.strip().split(' (')[0] for line in lines]

def rpaths(path):
    return re.findall(r'cmd LC_RPATH\n\s+cmdsize \d+\n\s+path (.*?) \(offset', output(['otool', '-l', path]))

def bundle_libraries(binary, frameworks):
    search = [BUILD_ROOT / 'native', BUILD_ROOT / 'core', CACHE / 'build/bin', CACHE / 'prefix/lib']
    pending = [binary]
    copied = set()
    origins = {binary: binary}
    while pending:
        path = pending.pop()
        for dep in libraries(path):
            if dep.startswith('/usr/lib/') or dep.startswith('/System/Library/'):
                continue
            name = Path(dep).name
            if name == path.name:  # LC_ID_DYLIB also appears in otool -L
                continue
            if dep.startswith('@rpath/'):
                original = next((p / name for p in search if (p / name).exists()), None)
            elif dep.startswith('@loader_path/'):
                original = origins[path].parent / dep.removeprefix('@loader_path/')
            elif dep.startswith('/'):
                original = Path(dep)
            else:
                raise RuntimeError(f'未知库路径 {dep}')
            if name not in copied:
                if original is None or not original.exists():
                    raise RuntimeError(f'无法解析 {dep}')
                target = frameworks / name
                shutil.copy2(original, target)
                target.chmod(0o755)
                copied.add(name)
                origins[target] = original
                run(['install_name_tool', '-id', '@rpath/' + name, target])
                pending.append(target)
            if dep != '@rpath/' + name:
                run(['install_name_tool', '-change', dep, '@rpath/' + name, path])
        for value in set(rpaths(path)):
            run(['install_name_tool', '-delete_rpath', value, path])
        run(['install_name_tool', '-add_rpath', '@loader_path' if path.parent == frameworks else '@executable_path/../Frameworks', path])
    # 签名顺序由内到外；自签仅适用于本机开发。
    for path in frameworks.iterdir():
        run(['codesign', '--force', '--sign', '-', path])
    run(['codesign', '--force', '--sign', '-', binary])
    for path in [binary, *frameworks.iterdir()]:
        deps = libraries(path)
        if any(not d.startswith(('/usr/lib/', '/System/Library/', '@rpath/')) for d in deps):
            raise RuntimeError(f'仍有外部动态库：{path}')
        if any(value.startswith('/') for value in rpaths(path)):
            raise RuntimeError(f'仍有绝对 rpath：{path}')

def licenses(destination):
    destination.mkdir(parents=True, exist_ok=True)
    manifest = json.loads((CACHE / 'manifest.json').read_text())
    for i, entry in enumerate(manifest['licenses']):
        source = Path(entry['path'])
        if not source.exists() or digest(source) != entry['sha256']:
            raise RuntimeError(f'许可证据变化：{source}')
        shutil.copy2(source, destination / f'{i:02d}-{source.name}')
    # 按实际打包的共享库选择许可；gettext命令行工具的GPL不是libintl的LGPL。
    framework_names = {p.name for p in (destination.parent / 'Frameworks').iterdir()}
    extra = []
    if any('zstd' in n for n in framework_names): extra.append((Path('/usr/local/opt/zstd/LICENSE'), 'zstd-BSD-LICENSE'))
    if any('lzma' in n for n in framework_names):
        extra += [(Path('/usr/local/opt/xz/COPYING'), 'xz-COPYING'), (Path('/usr/local/opt/xz/COPYING.0BSD'), 'xz-0BSD-LICENSE')]
    if any('boost' in n for n in framework_names): extra.append((ROOT / 'native/licenses/Boost-LICENSE.txt', 'Boost-LICENSE.txt'))
    if any('intl' in n for n in framework_names):
        extra += [(ROOT / 'native/licenses/libintl-NOTICE.txt', 'libintl-NOTICE.txt'), (Path('/usr/local/opt/xz/COPYING.LGPLv2.1'), 'libintl-LGPL-2.1.txt')]
    for source, name in extra:
        if not source.is_file(): raise RuntimeError(f'缺少依赖许可 {source}')
        shutil.copy2(source, destination / name)
    # 数据许可文本（英文词表／释义注释随包分发义务，见 docs/third-party.md）。
    data_licenses = ROOT / 'resources/licenses'
    if data_licenses.is_dir():
        for source in sorted(data_licenses.iterdir()):
            if source.is_file(): shutil.copy2(source, destination / source.name)
    (destination / 'upstream-manifest.json').write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + '\n')
    shutil.copy2(ROOT / 'docs/third-party.md', destination / 'THIRD-PARTY.md')

def write_build_identity(contents: Path, meta: dict) -> None:
    """包内身份：完整版本＋构建号＋提交＋dirty＋环境与依赖哈希（产物哈希在外部记录）。"""
    identity = {
        'fullVersion': meta['version'],
        'shortVersion': version_release(meta['version']),
        'stage': version_stage(meta['version']),
        'buildNumber': meta['buildNumber'],
        'commit': meta['git']['commit'],
        'dirty': meta['git']['dirty'],
        'arch': platform.machine(),
        'configuration': meta['configuration'],
        'validationBuild': meta['validation'],
        'abiVersion': 2,
    }
    lock = CACHE / 'dependencies.lock.json'
    if lock.exists():
        identity['dependencies'] = json.loads(lock.read_text())
    for name in ['english-wordlist-sources.json', 'gloss-sources.json']:
        source = ROOT / 'resources' / name
        if source.exists():
            identity.setdefault('dataSources', {})[name] = json.loads(source.read_text())
    (contents / 'Resources/build-identity.json').write_text(
        json.dumps(identity, ensure_ascii=False, indent=2) + '\n')


def assemble(name, executable, identifier, input_method=False, configuration='release', meta=None):
    app = DIST / (name + '.app')
    if app.exists(): shutil.rmtree(app)
    contents = app / 'Contents'
    for folder in ['MacOS', 'Resources', 'Frameworks', 'Helpers']:
        (contents / folder).mkdir(parents=True, exist_ok=True)
    source = BUILD_ROOT / 'swift' / configuration / executable
    binary = contents / 'MacOS' / executable
    shutil.copy2(source, binary)
    bundle_libraries(binary, contents / 'Frameworks')
    # CFBundleShortVersionString 只写三段数字（系统限制）；完整预发布版本
    # 在包内 build-identity.json，设置应用与诊断输出读取显示。
    info = {
        'CFBundleIdentifier': identifier, 'CFBundleName': name, 'CFBundleDisplayName': name,
        'CFBundleExecutable': executable, 'CFBundlePackageType': 'APPL',
        'CFBundleVersion': str(meta['buildNumber']),
        'CFBundleShortVersionString': version_release(meta['version']),
        'LSMinimumSystemVersion': '26.0', 'NSHighResolutionCapable': True,
        'CFBundleIconFile': 'AppIcon', 'CFBundleDevelopmentRegion': 'zh-Hans',
    }
    shutil.copy2(ROOT / 'assets/app-icon/AppIcon.icns', contents / 'Resources/AppIcon.icns')
    if input_method:
        info.update({
            'LSBackgroundOnly': True,
            # InputMethodConnectionName 仅对 Apple 白名单输入法生效，三方包写它只会触发
            # imklaunchagent "unrecognized" 噪音；实际连接名由框架派生为 bundleID.Connection。
            'InputMethodServerControllerClass': 'GogakuInputController',
            'TISInputSourceID': identifier, 'TISIntendedLanguage': 'zh-Hans',
            'tsInputMethodCharacterRepertoireKey': ['Hans'],
            'tsInputMethodLanguageKey': 'zh-Hans',
            'tsInputMethodIconFileKey': 'gogaku-menu.pdf',
            # TIS 从 ComponentInputModeDict 构建可选输入源；缺失时系统设置找不到该输入法。
            # 图标键必须带扩展名且与包内文件一致，否则系统设置的添加列表不显示该输入法。
            # 只声明 Caps Lock 切换能力；系统输入源切换由 macOS 管理。
            'TICapsLockLanguageSwitchCapable': True,
            'TISIconIsTemplate': False,
            'InputMethodType': 'Keyboard', 'NSPrincipalClass': 'NSApplication',
            'ComponentInputModeDict': {
                'tsInputModeListKey': {
                    f'{identifier}.Hans': {
                        'TISInputSourceID': f'{identifier}.Hans',
                        'TISIntendedLanguage': 'zh-Hans',
                        'tsInputModeCharacterRepertoireKey': ['Hans'],
                        'tsInputModeDefaultStateKey': True,
                        'tsInputModeIsVisibleKey': True,
                        'tsInputModeMenuIconFileKey': 'gogaku-menu.pdf',
                        'tsInputModeAlternateMenuIconFileKey': 'gogaku-menu.pdf',
                        'tsInputModePaletteIconFileKey': 'gogaku-menu.pdf',
                        'tsInputModePrimaryInScriptKey': True,
                        'tsInputModeScriptKey': 'smUnicodeScript',
                    },
                },
                'tsVisibleInputModeOrderedArrayKey': [f'{identifier}.Hans'],
            },
        })
        shutil.copy2(ROOT / 'assets/app-icon/gogaku-menu.pdf', contents / 'Resources/gogaku-menu.pdf')
        # 输入模式的显示名按模式 ID 从 InfoPlist.strings 查找；缺失时菜单里显示原始 ID。
        for folder, name in [('en.lproj', 'Gogaku'), ('zh-Hans.lproj', 'Gogaku')]:
            strings = contents / 'Resources' / folder
            strings.mkdir(parents=True)
            (strings / 'InfoPlist.strings').write_bytes(plistlib.dumps(
                {f'{identifier}.Hans': name, 'CFBundleDisplayName': name, 'CFBundleName': name}))
        data = contents / 'Resources/EngineData'; data.mkdir()
        lock = json.loads((CACHE / 'dependencies.lock.json').read_text())
        for filename, expected in lock['artifacts'].items():
            source = CACHE / 'data' / filename
            if digest(source) != expected: raise RuntimeError(f'资源校验失败 {filename}')
            # copyfile 而非 copy2：出厂文件带 uchg 保护标志时，copystat 会把
            # 不可变标志带进包，导致后续重装 rmtree／安装失败。
            shutil.copyfile(source, data / filename)
            (data / filename).chmod(0o644)
        # 英文候选／释义数据：只在生成物与来源清单都在且哈希一致时打包；
        # 任一缺失则按规格降级（无注释、无英文候选），不阻塞构建。
        for filename, manifest_name in [('english-words.txt', 'english-wordlist-sources.json'),
                                        ('gloss.tsv', 'gloss-sources.json')]:
            source = ROOT / 'resources' / filename
            manifest = ROOT / 'resources' / manifest_name
            if not source.exists() or not manifest.exists():
                print(f'提示：resources/{filename} 未生成，按降级形态打包（无该数据）')
                continue
            expected = json.loads(manifest.read_text())['output_sha256']
            if digest(source) != expected: raise RuntimeError(f'数据校验失败 {filename}')
            shutil.copy2(source, data / filename)
        shutil.copy2(CACHE / 'dependencies.lock.json', contents / 'Resources/dependencies.lock.json')
        helper = contents / 'Helpers/GogakuTranslator'
        shutil.copy2(BUILD_ROOT / 'swift' / configuration / 'GogakuTranslator', helper)
        bundle_libraries(helper, contents / 'Frameworks')
    (contents / 'Info.plist').write_bytes(plistlib.dumps(info))
    write_build_identity(contents, meta)
    licenses(contents / 'Licenses')
    run(['codesign', '--force', '--sign', '-', app])
    run(['codesign', '--verify', '--deep', '--strict', app])
    return app

def write_dist_identity(apps: list, meta: dict, configuration: str, validation: bool) -> Path:
    """外部身份记录：包内身份＋主程序／helper／动态库／安装包哈希（不写入包内）。"""
    def file_hash(path: Path) -> dict:
        return {'sha256': digest(path), 'bytes': path.stat().st_size}
    report = dict(
        fullVersion=meta['version'], buildNumber=meta['buildNumber'],
        stage=version_stage(meta['version']), commit=meta['git']['commit'],
        dirty=meta['git']['dirty'], arch=platform.machine(),
        configuration=configuration, validationBuild=validation,
        toolchain={'swift': output(['swift', '--version']).splitlines()[0].strip(),
                   'cmake': output(['cmake', '--version']).splitlines()[0].strip()},
        apps={},
    )
    for app in apps:
        entries = {}
        contents = app / 'Contents'
        for rel in ['MacOS', 'Helpers', 'Frameworks']:
            folder = contents / rel
            if folder.exists():
                for path in sorted(folder.iterdir()):
                    if path.is_file():
                        entries[str(path.relative_to(app))] = file_hash(path)
        entries[str((app / 'Contents/Info.plist').relative_to(app))] = file_hash(app / 'Contents/Info.plist')
        # 安装包是目录，不能直接哈希：对排序后的（相对路径，文件哈希）列表哈希，
        # 内容不变则哈希不变（plimmutable 快照语义）。
        bundle_fingerprint = json.dumps(entries, ensure_ascii=False, sort_keys=True)
        bundle_sha = hashlib.sha256(bundle_fingerprint.encode()).hexdigest()
        report['apps'][app.name] = {'bundleSha256': bundle_sha, 'files': entries,
                                    'identity': json.loads(
                                        (contents / 'Resources/build-identity.json').read_text())}
    out = DIST / 'build-identity.json'
    out.write_text(json.dumps(report, ensure_ascii=False, indent=2) + '\n')
    return out


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--prepare', action='store_true')
    parser.add_argument('--validation', action='store_true', help='包含默认关闭的无文字验收状态接口')
    parser.add_argument('--configuration', choices=['release', 'debug'], default='release',
                        help='Swift 构建配置（默认 release；debug 仅用于开发诊断）')
    args = parser.parse_args()
    meta = load_version()
    meta['git'] = git_identity()
    stage = version_stage(meta['version'])
    require_clean_allowed(stage, meta['git']['dirty'])
    if stage == 'final':
        tag = subprocess.run(['git', 'tag', '--list', 'v' + meta['version']], cwd=ROOT,
                             capture_output=True, text=True)
        if tag.stdout.strip():
            raise SystemExit(f"v{meta['version']} 标签已存在；定版标签不移动，请使用新版本号。")
    if meta['git']['dirty']:
        print(f"提示：工作区有未提交修改，构建身份标记 dirty=true（版本 {meta['version']}）")
    print(f"构建版本 {meta['version']}（构建号 {meta['buildNumber']}，{stage}，提交 {meta['git']['commit'][:12]}）")
    run(['swift', 'scripts/check-menu-icon.swift', ROOT / 'assets/app-icon/gogaku-menu.pdf'])
    if args.prepare or not (CACHE / 'dependencies.lock.json').exists(): run(['python3', 'scripts/prepare-dependencies.py', '--jobs', '2'])
    run(['cmake', '-S', 'native/EngineBridge', '-B', BUILD_ROOT / 'native', '-G', 'Ninja', '-DCMAKE_BUILD_TYPE=Release', '-DGOGAKU_DEPS=' + str(CACHE)])
    run(['cmake', '--build', BUILD_ROOT / 'native', '-j', '2'])
    # 共享普通模式核心（native/GogakuCore，ABI v2）。
    run(['cmake', '-S', 'native/GogakuCore', '-B', BUILD_ROOT / 'core', '-G', 'Ninja', '-DCMAKE_BUILD_TYPE=Release', '-DGOGAKU_DEPS=' + str(CACHE)])
    run(['cmake', '--build', BUILD_ROOT / 'core', '-j', '2'])
    run(['ctest', '--test-dir', BUILD_ROOT / 'core', '--output-on-failure'])
    swift_args = ['swift', 'build', '-c', args.configuration, '-j', '2', '--scratch-path', str(BUILD_ROOT / 'swift')]
    if args.validation: swift_args += ['-Xswiftc', '-DGOGAKU_VALIDATION']
    run(swift_args)
    DIST.mkdir(exist_ok=True)
    meta['configuration'] = args.configuration
    meta['validation'] = bool(args.validation)
    apps = [assemble('Gogaku', 'GogakuInput', 'org.gogaku.inputmethod', True, args.configuration, meta),
            assemble('Gogaku Settings', 'GogakuSettings', 'org.gogaku.settings',
                     configuration=args.configuration, meta=meta)]
    report = []
    for app in apps:
        for path in app.rglob('*'):
            if path.is_file(): report.append({'path': str(path.relative_to(DIST)), 'bytes': path.stat().st_size, 'sha256': digest(path)})
    (DIST / 'bundle-manifest.json').write_text(json.dumps(report, ensure_ascii=False, indent=2) + '\n')
    identity_path = write_dist_identity(apps, meta, args.configuration, bool(args.validation))
    print('\n'.join(str(app) for app in apps))
    print(f'构建身份：{identity_path}')
