#!/usr/bin/env python3
"""构建并组装仅依赖系统库/包内库的本机开发版；不注册/切换输入源。"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess

ROOT = Path(__file__).resolve().parent.parent
if 'DEVELOPER_DIR' not in os.environ and Path('/Applications/Xcode.app/Contents/Developer').is_dir():
    os.environ['DEVELOPER_DIR'] = '/Applications/Xcode.app/Contents/Developer'
CACHE = Path(os.environ.get('GOGAKU_DEPS', Path.home() / 'Library/Caches/Gogaku/libime-1.1.17'))
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
    search = [ROOT / '.build/native', ROOT / '.build/core', CACHE / 'build/bin', CACHE / 'prefix/lib']
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

def assemble(name, executable, identifier, input_method=False, configuration='release'):
    app = DIST / (name + '.app')
    if app.exists(): shutil.rmtree(app)
    contents = app / 'Contents'
    for folder in ['MacOS', 'Resources', 'Frameworks', 'Helpers']:
        (contents / folder).mkdir(parents=True, exist_ok=True)
    source = ROOT / '.build' / configuration / executable
    binary = contents / 'MacOS' / executable
    shutil.copy2(source, binary)
    bundle_libraries(binary, contents / 'Frameworks')
    info = {
        'CFBundleIdentifier': identifier, 'CFBundleName': name, 'CFBundleDisplayName': name,
        'CFBundleExecutable': executable, 'CFBundlePackageType': 'APPL',
        'CFBundleVersion': '1', 'CFBundleShortVersionString': '0.1.0',
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
            shutil.copy2(source, data / filename)
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
        shutil.copy2(ROOT / '.build' / configuration / 'GogakuTranslator', helper)
        bundle_libraries(helper, contents / 'Frameworks')
    (contents / 'Info.plist').write_bytes(plistlib.dumps(info))
    licenses(contents / 'Licenses')
    run(['codesign', '--force', '--sign', '-', app])
    run(['codesign', '--verify', '--deep', '--strict', app])
    return app

if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--prepare', action='store_true')
    parser.add_argument('--validation', action='store_true', help='包含默认关闭的无文字验收状态接口')
    parser.add_argument('--configuration', choices=['release', 'debug'], default='release',
                        help='Swift 构建配置（默认 release；debug 仅用于开发诊断）')
    args = parser.parse_args()
    run(['swift', 'scripts/check-menu-icon.swift', ROOT / 'assets/app-icon/gogaku-menu.pdf'])
    if args.prepare or not (CACHE / 'dependencies.lock.json').exists(): run(['python3', 'scripts/prepare-dependencies.py', '--jobs', '2'])
    run(['cmake', '-S', 'native/EngineBridge', '-B', '.build/native', '-G', 'Ninja', '-DCMAKE_BUILD_TYPE=Release', '-DGOGAKU_DEPS=' + str(CACHE)])
    run(['cmake', '--build', '.build/native', '-j', '2'])
    # 共享普通模式核心（native/GogakuCore，ABI v2）。
    run(['cmake', '-S', 'native/GogakuCore', '-B', '.build/core', '-G', 'Ninja', '-DCMAKE_BUILD_TYPE=Release', '-DGOGAKU_DEPS=' + str(CACHE)])
    run(['cmake', '--build', '.build/core', '-j', '2'])
    run(['ctest', '--test-dir', '.build/core', '--output-on-failure'])
    swift_args = ['swift', 'build', '-c', args.configuration, '-j', '2']
    if args.validation: swift_args += ['-Xswiftc', '-DGOGAKU_VALIDATION']
    run(swift_args)
    DIST.mkdir(exist_ok=True)
    apps = [assemble('Gogaku', 'GogakuInput', 'org.gogaku.inputmethod', True, args.configuration),
            assemble('Gogaku Settings', 'GogakuSettings', 'org.gogaku.settings', configuration=args.configuration)]
    report = []
    for app in apps:
        for path in app.rglob('*'):
            if path.is_file(): report.append({'path': str(path.relative_to(DIST)), 'bytes': path.stat().st_size, 'sha256': digest(path)})
    (DIST / 'bundle-manifest.json').write_text(json.dumps(report, ensure_ascii=False, indent=2) + '\n')
    print('\n'.join(str(app) for app in apps))
