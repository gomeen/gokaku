#!/usr/bin/env python3
"""仅管理 Gogaku 自身的当前用户安装；保留其他输入源与用户数据。

双通道：--channel dev 安装 Gogaku Dev（bundle ID 带 .dev 后缀，独立输入源），
与 stable 并存；用户数据两通道共用同一份（2026-11-06 裁决）。"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import tempfile
import time

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(Path(__file__).resolve().parent))
from _gogaku_dist import apply_tis_identity, deterministic_plist_bytes  # noqa: E402
# 双通道（2026-11-06 裁决）：stable=Gogaku（日常），dev=Gogaku Dev（测试）。
# bundle ID 带 .dev 后缀 → 独立输入源与安装路径，可与 stable 并存；
# 用户数据与 Darwin 通知共用同一份（SUPPORT 不分通道）。
CHANNELS = {
    'stable': {
        'input_name': 'Gogaku.app', 'settings_name': 'Gogaku Settings.app',
        'input_id': 'org.gogaku.inputmethod', 'settings_id': 'org.gogaku.settings',
    },
    'dev': {
        'input_name': 'Gogaku Dev.app', 'settings_name': 'Gogaku Settings Dev.app',
        'input_id': 'org.gogaku.inputmethod.dev', 'settings_id': 'org.gogaku.settings.dev',
    },
}
CHANNEL = 'stable'
INPUT = Path.home() / 'Library/Input Methods' / CHANNELS[CHANNEL]['input_name']
SETTINGS = Path.home() / 'Applications' / CHANNELS[CHANNEL]['settings_name']
INPUT_ID = CHANNELS[CHANNEL]['input_id']
SUPPORT = Path.home() / 'Library/Application Support/Gogaku'


def set_channel(name):
    global CHANNEL, INPUT, SETTINGS, INPUT_ID
    CHANNEL = name
    INPUT = Path.home() / 'Library/Input Methods' / CHANNELS[name]['input_name']
    SETTINGS = Path.home() / 'Applications' / CHANNELS[name]['settings_name']
    INPUT_ID = CHANNELS[name]['input_id']
LSREGISTER = '/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister'
# 开发备份保留份数；更早的备份按时间删除，避免旧二进制无限累积。
KEEP_BACKUPS = 3

def current_is_gogaku(identifier=None):
    # 只读当前输入源标识，不扫描任何私人输入历史。
    identifier = identifier or INPUT_ID
    result = subprocess.run(['defaults', 'read', 'com.apple.HIToolbox', 'AppleSelectedInputSources'], capture_output=True, text=True)
    return identifier in result.stdout

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
    防止旧包残留、拷贝损坏或旧备份包冒充新版本。
    必须在身份注入前调用：注入后的 ad-hoc 重签会改写主程序内嵌签名，
    二进制字节偏离 dist 清单（注入后的核对靠 plist 期望字节＋签名有效性）。"""
    manifest_path = ROOT / 'dist' / ('bundle-manifest.json' if CHANNEL == 'stable'
                                     else 'bundle-manifest-dev.json')
    if not manifest_path.exists():
        raise SystemExit(f'缺少 {manifest_path.relative_to(ROOT)}；请用 scripts/build.py（同通道）构建后再安装。')
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
    if current_is_gogaku():
        raise SystemExit(f'当前输入源是本通道（{CHANNEL}）；请先切换到 ABC 或其他输入源，再更新。')
    other = 'dev' if CHANNEL == 'stable' else 'stable'
    print(f'安装通道：{CHANNEL}（输入法 {INPUT.name}，bundle ID {INPUT_ID}）')
    print(f'与 {other} 通道并存：用户数据共用 {SUPPORT}，互不覆盖。')
    import plistlib
    for source, target, identifier, needs_identity in [
            (ROOT / 'dist' / CHANNELS[CHANNEL]['input_name'], INPUT, INPUT_ID, True),
            (ROOT / 'dist' / CHANNELS[CHANNEL]['settings_name'], SETTINGS,
             CHANNELS[CHANNEL]['settings_id'], False)]:
        subprocess.run(['codesign', '--verify', '--deep', '--strict', source], check=True)
        own(target, identifier)
        target.parent.mkdir(parents=True, exist_ok=True)
        backup(target)
        shutil.copytree(source, target, symlinks=True)
        # 拷贝完整性先核对（逐字节等于中立 dist：防旧包残留／拷贝损坏／旧备份
        # 冒充），再做身份注入——注入后的 ad-hoc 重签会改写主程序内嵌签名
        # （CD 含 Info.plist 哈希），安装位二进制字节必然偏离 dist 清单；
        # 注入后只按 plist 期望字节与签名有效性核对（2026-11-06 dev 通道
        # 实装发现：重签后哈希核对必挂）。
        verify_install(source, target)
        if needs_identity:
            # 中立 dist → 安装位注入输入源身份（_gogaku_dist 约定）＋ad-hoc 重签。
            info_path = target / 'Contents/Info.plist'
            info = plistlib.loads(info_path.read_bytes())
            patched = deterministic_plist_bytes(apply_tis_identity(info, identifier))
            info_path.write_bytes(patched)
            subprocess.run(['codesign', '--force', '--deep', '--sign', '-', target], check=True)
            if info_path.read_bytes() != patched:
                raise SystemExit(f'身份注入失败：{info_path}')
            subprocess.run(['codesign', '--verify', '--deep', '--strict', target], check=True)
    # imklaunchagent 的输入法启动路径依赖 LaunchServices 数据库；
    # 移包重装会丢失登记，必须重新注册，否则系统不拉起输入法进程。
    subprocess.run([LSREGISTER, '-f', str(INPUT)], check=False)
    # Refresh bundle metadata (including menu icons) once during installation.
    # Registering does not enable/select a source or repeat the consent prompt.
    run_tis([str(INPUT)])
    # HUD 进程内缓存的旧图标不会随注册刷新（见 refresh_hud_icon_cache 注释），
    # 重装图标资源后必须让 TextInputSwitcher 重建，切换浮层才显示新键帽图标。
    refresh_hud_icon_cache()
    print(f'已安装（{CHANNEL} 通道）：{INPUT}\n设置：{SETTINGS}')
    flag = ' --channel dev' if CHANNEL == 'dev' else ''
    print(f'如系统输入源列表还没有本通道，运行 python3 scripts/manage-install.py{flag} register；')
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
    else:
        # 本机实测：kickstart 对该系统按需代理可能被 SIP 拒绝（Operation not
        # permitted）；killall -9 等效（进程属当前用户，launchd ResetAtClose
        # 拉起新进程），实曾在 2026-11-02 验证可用。
        fallback = subprocess.run(['killall', '-9', 'TextInputSwitcher'],
                                  capture_output=True, text=True)
        if fallback.returncode == 0:
            print('已重启输入源切换 HUD（killall）：下次切换输入源时按新包重建图标。')
        else:
            reason = result.stderr.strip() or f'exit={result.returncode}'
            print(f'提示：未能自动重启输入源切换 HUD（{reason}）；注销并重新登录一次可达到同样效果。')

def uninstall(purge):
    if current_is_gogaku():
        raise SystemExit(f'当前输入源是本通道（{CHANNEL}）；请先切换到其他输入源并在系统设置中移除，再卸载。')
    for path, identifier in [(INPUT, INPUT_ID), (SETTINGS, CHANNELS[CHANNEL]['settings_id'])]:
        own(path, identifier)
        if path.exists(): shutil.rmtree(path)
    print(f'已移除 {CHANNEL} 通道应用。学习数据与开发备份默认保留（两通道共用）。')
    if purge and SUPPORT.exists():
        print('注意：用户数据两通道共用，删除会影响另一个通道。')
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
    other = 'dev' if CHANNEL == 'stable' else 'stable'
    o = CHANNELS[other]
    state = {
        'channel': CHANNEL,
        'input_installed': INPUT.exists(), 'settings_installed': SETTINGS.exists(),
        'current_is_gogaku': current_is_gogaku(),
        'other_channel': {
            'input_installed': (Path.home() / 'Library/Input Methods' / o['input_name']).exists(),
            'input_id': o['input_id'],
        },
    }
    for app in [INPUT, SETTINGS]:
        if app.exists():
            result = subprocess.run(['codesign', '--verify', '--deep', '--strict', app], capture_output=True, text=True)
            state[app.name + '_signature_ok'] = result.returncode == 0
    print(json.dumps(state, ensure_ascii=False, indent=2))

TIS_SCRIPT = '''import Carbon
import Foundation
let identifier = "__INPUT_ID__"
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
    script = Path(tempfile.gettempdir()) / ('gogaku-tis-' + CHANNEL + '.swift')
    script.write_text(TIS_SCRIPT.replace('__INPUT_ID__', INPUT_ID))
    return subprocess.run(developer_dir + ['swift', str(script), *args], text=True, capture_output=True, check=True).stdout

def register():
    if not INPUT.exists(): raise SystemExit(f'未找到 {CHANNEL} 通道已安装的输入法，先执行 install。')
    # 只登记已安装的包让系统设置可见；不启用、不选中，切换仍由用户手动完成。
    print(run_tis([str(INPUT)]).strip())
    print(run_tis([]).strip())

if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=['install', 'register', 'uninstall', 'recover', 'diagnose'])
    parser.add_argument('--purge-data', action='store_true')
    parser.add_argument('--channel', choices=sorted(CHANNELS), default='stable',
                        help='安装通道：stable（默认）／dev；dev 装为 Gogaku Dev，独立输入源，数据共用')
    args = parser.parse_args()
    set_channel(args.channel)
    {'install': install, 'register': register, 'uninstall': lambda: uninstall(args.purge_data), 'recover': recover, 'diagnose': diagnose}[args.action]()
