#!/usr/bin/env python3
"""仅管理 Gogaku 自身的当前用户安装；保留其他输入源与用户数据。"""
import argparse
import json
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
    if path.exists():
        directory = SUPPORT / 'DeveloperBackups' / time.strftime('%Y%m%d-%H%M%S')
        directory.mkdir(parents=True, exist_ok=True)
        shutil.move(str(path), str(directory / path.name))

def install():
    if current_is_gogaku(): raise SystemExit('请先手动切换到 ABC 或其他现有输入源，再更新 Gogaku。')
    for source, target, identifier in [(ROOT / 'dist/Gogaku.app', INPUT, 'org.gogaku.inputmethod'), (ROOT / 'dist/Gogaku Settings.app', SETTINGS, 'org.gogaku.settings')]:
        subprocess.run(['codesign', '--verify', '--deep', '--strict', source], check=True)
        own(target, identifier)
        target.parent.mkdir(parents=True, exist_ok=True)
        backup(target)
        shutil.copytree(source, target, symlinks=True)
    # imklaunchagent 的输入法启动路径依赖 LaunchServices 数据库；
    # 移包重装会丢失登记，必须重新注册，否则系统不拉起输入法进程。
    subprocess.run([LSREGISTER, '-f', str(INPUT)], check=False)
    # Refresh bundle metadata (including menu icons) once during installation.
    # Registering does not enable/select a source or repeat the consent prompt.
    run_tis([str(INPUT)])
    print(f'已安装：{INPUT}\n设置：{SETTINGS}')
    print('如系统输入源列表还没有 Gogaku，运行 python3 scripts/manage-install.py register；')
    print('或自行注销后重新登录。然后在 系统设置 → 键盘 → 文本输入 → 编辑 → ＋ 中手动添加并切换。')

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
