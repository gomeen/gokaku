#!/usr/bin/env python3
"""仅管理 Gogaku 自身的当前用户安装；保留其他输入源与用户数据。"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parent.parent
INPUT = Path.home() / 'Library/Input Methods/Gogaku.app'
SETTINGS = Path.home() / 'Applications/Gogaku Settings.app'
SUPPORT = Path.home() / 'Library/Application Support/Gogaku'
LSREGISTER = '/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister'
# 开发备份保留份数；更早的备份按时间删除，避免旧二进制无限累积。
KEEP_BACKUPS = 3

def current_is_gogaku():
    # 只读当前输入源标识，不扫描任何私人输入历史。
    result = subprocess.run(['defaults', 'read', 'com.apple.HIToolbox', 'AppleSelectedInputSources'], capture_output=True, text=True)
    return 'org.gogaku.inputmethod' in result.stdout

def own(path, identifier):
    if not path.exists(): return
    info = plistlib.loads((path / 'Contents/Info.plist').read_bytes())
    if info.get('CFBundleIdentifier') != identifier:
        raise SystemExit(f'拒绝覆盖非 Gogaku 应用：{path}')

def backup(path):
    if not path.exists():
        return
    directory = SUPPORT / 'DeveloperBackups' / time.strftime('%Y%m%d-%H%M%S')
    directory.mkdir(parents=True, exist_ok=True)
    # 备份不能保留 .app 扩展名：LaunchServices 会索引 Application Support 里的
    # .app 并可能在输入法启动时捡到旧二进制（曾发生 76 个旧备份包随机启动）。
    # 改为 .app.disabled 后 LS 不再把它当作可启动应用。
    target = directory / (path.name + '.disabled')
    shutil.move(str(path), str(target))
    prune_backups()

def prune_backups():
    root = SUPPORT / 'DeveloperBackups'
    if not root.exists():
        return
    # 旧版脚本留下的 *.app 备份一并改名，消除被 LaunchServices 误启动的隐患。
    for d in root.iterdir():
        if not d.is_dir():
            continue
        for legacy in d.glob('*.app'):
            legacy.rename(legacy.with_name(legacy.name + '.disabled'))
    entries = sorted((d for d in root.iterdir() if d.is_dir()), key=lambda d: d.name)
    for stale in entries[:-KEEP_BACKUPS] if len(entries) > KEEP_BACKUPS else []:
        shutil.rmtree(stale, ignore_errors=True)

def verify_install(source: Path, target: Path):
    """安装后核对：实际安装路径的每个文件与 dist 清单哈希一致。
    防止旧包残留、拷贝损坏或旧备份包冒充新版本。"""
    manifest_path = ROOT / 'dist' / 'bundle-manifest.json'
    if not manifest_path.exists():
        raise SystemExit('缺少 dist/bundle-manifest.json；请用 scripts/build.py 构建后再安装。')
    manifest = {entry['path']: entry for entry in json.loads(manifest_path.read_text())}
    # build.py 写入的 manifest 路径相对于 dist（如 'Gogaku.app/Contents/...'），
    # 不是绝对路径；前缀必须按同一基准算，否则一个条目都匹配不上。
    prefix = str(source.relative_to(manifest_path.parent)) + '/'
    installed = {str(p): p for p in target.rglob('*') if p.is_file()}
    for rel, entry in manifest.items():
        if not rel.startswith(prefix):
            continue
        installed_path = target / rel.removeprefix(prefix)
        if not installed_path.is_file():
            raise SystemExit(f'安装不完整：缺少 {rel}')
        if file_digest(installed_path) != entry['sha256']:
            raise SystemExit(f'哈希不一致：{installed_path}（期望 {entry["sha256"][:12]}…）')
        installed.pop(str(installed_path), None)
    extra = [p for p in installed if '__pycache__' not in p]
    if extra:
        raise SystemExit(f'安装目录含清单外文件：{extra[:3]}')
    print(f'已核对 {target} 运行时哈希（{sum(1 for r in manifest if r.startswith(prefix))} 个文件与 dist 清单一致）')

def file_digest(path: Path) -> str:
    with path.open('rb') as f:
        return hashlib.file_digest(f, 'sha256').hexdigest()

def install():
    if current_is_gogaku(): raise SystemExit('请先手动切换到 ABC 或其他现有输入源，再更新 Gogaku。')
    for source, target, identifier in [(ROOT / 'dist/Gogaku.app', INPUT, 'org.gogaku.inputmethod'), (ROOT / 'dist/Gogaku Settings.app', SETTINGS, 'org.gogaku.settings')]:
        subprocess.run(['codesign', '--verify', '--deep', '--strict', source], check=True)
        own(target, identifier)
        target.parent.mkdir(parents=True, exist_ok=True)
        backup(target)
        shutil.copytree(source, target, symlinks=True)
        verify_install(source, target)
    # imklaunchagent 的输入法启动路径依赖 LaunchServices 数据库；
    # 移包重装会丢失登记，必须重新注册，否则系统不拉起输入法进程。
    subprocess.run([LSREGISTER, '-f', str(INPUT)], check=False)
    # Refresh bundle metadata (including menu icons) once during installation.
    # Registering does not enable/select a source or repeat the consent prompt.
    run_tis([str(INPUT)])
    # HUD 进程内缓存的旧图标不会随注册刷新（见 refresh_hud_icon_cache 注释），
    # 重装图标资源后必须让 TextInputSwitcher 重建，切换浮层才显示新键帽图标。
    refresh_hud_icon_cache()
    print(f'已安装：{INPUT}\n设置：{SETTINGS}')
    print('如系统输入源列表还没有 Gogaku，运行 python3 scripts/manage-install.py register；')
    print('或自行注销后重新登录。然后在 系统设置 → 键盘 → 文本输入 → 编辑 → ＋ 中手动添加并切换。')

def refresh_hud_icon_cache():
    """重启输入源切换 HUD 代理，让它下次显示时从当前安装包重建图标。

    依据 2026-11 只读调查（probes/tis-icon-probe.swift、probes/render-hud-paths.swift）：
    - TIS 的图标 URL 始终指向安装包内 gogaku-menu.pdf，磁盘无图标位图缓存
      （com.apple.IntlDataCache.le.kbdx 只存输入源注册表，无位图）；
    - HUD 由 com.apple.TextInputSwitcher 渲染，它把每个输入源的 NSImage 缓存在
      进程内 InputSource 对象上（fIconImage/fCustomIcon 等），进程不重启不重读；
    - 该代理常驻跨安装（曾观察到自键帽图标首个安装前运行至今），导致 HUD 一直
      显示旧包的裸笔画图标，而菜单栏按需重读所以正常。
    launchd 将其登记为 Aqua 按需服务（MachServices 带 ResetAtClose/HideUntilCheckIn），
    kickstart -k 后任何输入源切换都会拉起新进程并重建图标，无需注销。
    回滚安全性：仅影响 HUD 进程自身；失败时仅提示手动注销一次，不阻断安装。
    """
    result = subprocess.run(['launchctl', 'kickstart', '-k',
                             f'gui/{os.getuid()}/com.apple.TextInputSwitcher'],
                            capture_output=True, text=True)
    if result.returncode == 0:
        print('已重启输入源切换 HUD（TextInputSwitcher）：下次切换输入源时按新包重建图标。')
        print('若切换浮层仍显示旧图，运行 launchctl kickstart -k gui/$UID/com.apple.TextInputSwitcher；'
              '仍不行则注销并重新登录一次。')
    else:
        reason = result.stderr.strip() or f'exit={result.returncode}'
        print(f'提示：未能自动重启输入源切换 HUD（{reason}）；注销并重新登录一次可达到同样效果。')

def uninstall(purge):
    if current_is_gogaku(): raise SystemExit('请先手动切换到其他输入源，并在系统设置中移除 Gogaku，再卸载。')
    for path, identifier in [(INPUT, 'org.gogaku.inputmethod'), (SETTINGS, 'org.gogaku.settings')]:
        own(path, identifier)
        if path.exists(): shutil.rmtree(path)
    print('已移除 Gogaku 应用。学习数据与开发备份默认保留。')
    if purge and SUPPORT.exists():
        if input(f'将永久删除 {SUPPORT}。输入 DELETE 确认：') != 'DELETE':
            raise SystemExit('已保留数据。')
        shutil.rmtree(SUPPORT)
        print('已删除 Gogaku 用户数据。系统语言包仍由系统管理。')

def recover():
    print('1. 先手动切换到 ABC 或任一已有输入源；Gogaku 不会自动切换输入源。')
    print('2. 在系统设置的键盘/文本输入中暂时移除 Gogaku；不要关闭系统安全机制。')
    print('3. 运行 python3 scripts/manage-install.py diagnose，重新构建后再 install。')
    print(f'4. 上一版应用若存在，保留在 {SUPPORT / "DeveloperBackups"}；用户数据不随重装删除。')
    print('5. 重新添加输入源。如果系统尚未刷新，可自行选择注销/登录；脚本不擅自注销。')

def diagnose():
    state = {'input_installed': INPUT.exists(), 'settings_installed': SETTINGS.exists(), 'current_is_gogaku': current_is_gogaku()}
    for app in [INPUT, SETTINGS]:
        if app.exists():
            result = subprocess.run(['codesign', '--verify', '--deep', '--strict', app], capture_output=True, text=True)
            state[app.name + '_signature_ok'] = result.returncode == 0
    print(json.dumps(state, ensure_ascii=False, indent=2))

TIS_SCRIPT = '''import Carbon
import Foundation
let identifier = "org.gogaku.inputmethod"
if CommandLine.arguments.count > 1 {
    let status = TISRegisterInputSource(URL(fileURLWithPath: CommandLine.arguments[1]) as CFURL)
    print("TISRegisterInputSource -> \\(status)")
    if status != noErr { exit(70) }
}
let filter = [kTISPropertyBundleID as String: identifier] as CFDictionary
guard let list = TISCreateInputSourceList(filter, true)?.takeRetainedValue() else {
    print(#"{"bundleID":"\\(identifier)","registered":false}"#)
    exit(2)
}
func property(_ source: TISInputSource, _ key: CFString) -> Any? {
    guard let pointer = TISGetInputSourceProperty(source, key) else { return nil }
    return Unmanaged<CFTypeRef>.fromOpaque(pointer).takeUnretainedValue()
}
let rows: [[String: Any]] = (list as! [TISInputSource]).map { source in
    ["id": property(source, kTISPropertyInputSourceID) as? String ?? "",
     "name": property(source, kTISPropertyLocalizedName) as? String ?? "",
     "enabled": (property(source, kTISPropertyInputSourceIsEnabled) as? NSNumber)?.boolValue ?? false,
     "selected": (property(source, kTISPropertyInputSourceIsSelected) as? NSNumber)?.boolValue ?? false]
}
print(String(decoding: try JSONSerialization.data(withJSONObject: ["registered": !rows.isEmpty, "sources": rows], options: [.prettyPrinted, .sortedKeys]), as: UTF8.self))
exit(rows.isEmpty ? 2 : 0)
'''

def run_tis(args):
    developer_dir = ['/usr/bin/env', 'DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer'] if Path('/Applications/Xcode.app/Contents/Developer').is_dir() else ['/usr/bin/env']
    script = Path(tempfile.gettempdir()) / 'gogaku-tis.swift'
    script.write_text(TIS_SCRIPT)
    return subprocess.run(developer_dir + ['swift', str(script), *args], text=True, capture_output=True, check=True).stdout

def register():
    if not INPUT.exists(): raise SystemExit('未找到已安装的输入法，先执行 install。')
    # 只登记已安装的包让系统设置可见；不启用、不选中，切换仍由用户手动完成。
    print(run_tis([str(INPUT)]).strip())
    print(run_tis([]).strip())

if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=['install', 'register', 'uninstall', 'recover', 'diagnose'])
    parser.add_argument('--purge-data', action='store_true')
    args = parser.parse_args()
    {'install': install, 'register': register, 'uninstall': lambda: uninstall(args.purge_data), 'recover': recover, 'diagnose': diagnose}[args.action]()
