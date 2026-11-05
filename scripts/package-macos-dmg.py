#!/usr/bin/env python3
"""把 dist 里的双 App 打成标准 DMG 安装包（macOS）。

输入：scripts/build.py 产物（dist/Gogaku.app＋Gogaku Settings.app，或 --channel dev 的 Dev 版）。
输出：dist/Gogaku-<版本>-b<构建号>[-dev].dmg，附带 SHA-256。

为什么不是「拖到 Applications」的 DMG：Gogaku 是输入法，macOS 只从
~/Library/Input Methods/ 加载输入法；且 DMG 拷出的文件带 com.apple.quarantine
隔离标记，会拦输入法进程（imklaunchagent）。DMG 内置「安装 Gogaku.command」
双击即装：拷贝到位→去隔离→重新注册→打开系统设置键盘面板。Squirrel 等输入法
用 pkg 解决同一问题；DMG＋command 是无签名的最接近常规体验。

用法：python3 scripts/package-macos-dmg.py [--channel stable|dev]
前置：先跑 scripts/build.py（同通道）。
"""
import argparse
import hashlib
import json
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
DIST = ROOT / 'dist'
LSREGISTER = ('/System/Library/Frameworks/CoreServices.framework/Frameworks/'
              'LaunchServices.framework/Support/lsregister')

CHANNELS = {
    'stable': {'input': 'Gogaku.app', 'settings': 'Gogaku Settings.app', 'suffix': ''},
    'dev': {'input': 'Gogaku Dev.app', 'settings': 'Gogaku Settings Dev.app', 'suffix': '-dev'},
}


def sha256(path: Path) -> str:
    h = hashlib.sha256()
    with open(path, 'rb') as f:
        for chunk in iter(lambda: f.read(1 << 20), b''):
            h.update(chunk)
    return h.hexdigest()


def installer_command(channel: dict) -> str:
    return f'''#!/bin/bash
# Gogaku 输入法安装器（双击运行）。来自 DMG，替换同名安装而不动其他输入源。
set -e
cd "$(dirname "$0")"

IM_DIR="$HOME/Library/Input Methods"
APPS_DIR="$HOME/Applications"
INPUT_APP="{channel['input']}"
SETTINGS_APP="{channel['settings']}"

echo "安装 $INPUT_APP 与 $SETTINGS_APP（已有版本自动替换，用户数据不受影响）…"
mkdir -p "$IM_DIR" "$APPS_DIR"
rm -rf "$IM_DIR/$INPUT_APP" "$APPS_DIR/$SETTINGS_APP"
cp -R "$INPUT_APP" "$IM_DIR/"
cp -R "$SETTINGS_APP" "$APPS_DIR/"

# dist 中立 → 目标位注入输入源身份＋ad-hoc 重签；再去 DMG 隔离标记。
cp "$(dirname "$0")/Info-tis-input.plist" "$IM_DIR/$INPUT_APP/Contents/Info.plist"
codesign --force --deep --sign - "$IM_DIR/$INPUT_APP" 2>/dev/null
xattr -dr com.apple.quarantine "$IM_DIR/$INPUT_APP" "$APPS_DIR/$SETTINGS_APP" 2>/dev/null || true

# 重新注册 LaunchServices（移包重装会丢登记，否则系统不拉起输入法进程）。
{LSREGISTER} -f "$IM_DIR/$INPUT_APP" >/dev/null 2>&1 || true

echo ""
echo "✅ 安装完成。最后一步（macOS 安全设计，必须手动）："
echo "  系统设置 → 键盘 → 文本输入 → 输入法 → 编辑 → ＋ → 添加 Gogaku"
echo "（正在为你打开系统设置…）"
open "x-apple.systempreferences:com.apple.Keyboard-Settings.extension"
echo ""
read -n 1 -s -r -p "按任意键关闭本窗口…"
'''


def readme_text(meta: dict, channel: dict) -> str:
    return f'''Gogaku 输入法安装说明
=====================

版本：{meta['version']}（构建号 {meta['buildNumber']}）{'（开发测试通道）' if channel['suffix'] else ''}

安装步骤（约 1 分钟）：
1. 双击「安装 Gogaku.command」。
   - 若 macOS 提示无法验证开发者：右键点击它 → 打开 → 再点「打开」。
     （本安装包未签名；这是无签名包的正常提示，不是包有问题。）
2. 脚本会把输入法装到 ~/Library/Input Methods/，设置应用装到 ~/Applications/。
3. 脚本会自动打开系统设置的键盘面板；在「文本输入 → 输入法」点 ＋
   添加 Gogaku，然后在菜单栏输入法菜单里切换到它即可使用。

卸载：
- 删除 ~/Library/Input Methods/{channel['input']} 与
  ~/Applications/{channel['settings']} 即可；
  学习数据在 ~/Library/Application Support/Gogaku/，默认保留。

说明：
- 不联网、不注入其他应用、不改动系统输入源设置；切换输入源始终由你手动完成。
- 本包为开发版交付（未签名、未公证），仅用于本机与受邀测试。
'''


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--channel', choices=sorted(CHANNELS), default='stable')
    args = parser.parse_args()
    channel = CHANNELS[args.channel]

    meta = json.loads((ROOT / 'version.json').read_text())
    input_app = DIST / channel['input']
    settings_app = DIST / channel['settings']
    for app in (input_app, settings_app):
        if not app.exists():
            raise SystemExit(f'缺少 {app.relative_to(ROOT)}；先用 scripts/build.py'
                             f'{" --channel " + args.channel if args.channel != "stable" else ""} 构建')

    stage = DIST / f'Gogaku-dmg-stage{channel["suffix"]}'
    if stage.exists():
        subprocess.run(['rm', '-rf', str(stage)], check=True)
    stage.mkdir()
    subprocess.run(['cp', '-R', str(input_app), str(stage / channel['input'])], check=True)
    subprocess.run(['cp', '-R', str(settings_app), str(stage / channel['settings'])], check=True)

    # dist 中立 → 随 DMG 携带身份 plist，安装 command 在目标位注入＋重签。
    import sys
    sys.path.insert(0, str(Path(__file__).resolve().parent))
    from _gogaku_dist import apply_tis_identity, deterministic_plist_bytes
    import plistlib
    info = plistlib.loads((input_app / 'Contents/Info.plist').read_bytes())
    (stage / 'Info-tis-input.plist').write_bytes(
        deterministic_plist_bytes(apply_tis_identity(info, info['CFBundleIdentifier'])))

    cmd = stage / ('安装 Gogaku.command' if args.channel == 'stable' else '安装 Gogaku Dev.command')
    cmd.write_text(installer_command(channel))
    cmd.chmod(0o755)
    (stage / '安装说明.txt').write_text(readme_text(meta, channel))

    dmg_name = f"Gogaku-{meta['version']}-b{meta['buildNumber']}{channel['suffix']}.dmg"
    dmg_path = DIST / dmg_name
    if dmg_path.exists():
        dmg_path.unlink()
    subprocess.run(['hdiutil', 'create', '-volname', f'Gogaku {meta["version"]}',
                    '-srcfolder', str(stage), '-format', 'UDZO', '-quiet', str(dmg_path)],
                   check=True)
    subprocess.run(['rm', '-rf', str(stage)], check=True)

    # 卫生：打包阶段的 staging 目录会被 LaunchServices 扫描注册成输入源幽灵；
    # 已删除 staging，产物路径再注销一次。注意：DMG 挂载卷本身也会被扫描注册，
    # 输入法分发推荐用 pkg（见 docs/release.md）。
    for app in (input_app, settings_app):
        subprocess.run([LSREGISTER, '-u', str(app)], capture_output=True)

    digest = sha256(dmg_path)
    (DIST / (dmg_name + '.sha256')).write_text(digest + '  ' + dmg_name + '\n')
    print(f'✅ DMG：{dmg_path}')
    print(f'   大小：{dmg_path.stat().st_size / 1048576:.1f} MB')
    print(f'   SHA-256：{digest}')
    print('安装方式：双击 DMG → 双击「安装 Gogaku.command」→ 按提示在系统设置添加输入源。')


if __name__ == '__main__':
    main()
