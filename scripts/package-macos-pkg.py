#!/usr/bin/env python3
"""把 dist 里的双 App 打成标准 .pkg 安装包（macOS 输入法惯例，Squirrel 同款路线）。

为什么 pkg 优于 DMG（对输入法）：
- 安装器装出的文件不带 com.apple.quarantine 隔离标记（DMG 拷出会带，输入法
  进程会被拦，需要额外去隔离）；
- 原生安装器体验：双击 → 欢迎/说明 → 安装 → 完成；
- postinstall 自动放位＋重新注册 LaunchServices，无需 Terminal。

设计：
- 用户级安装（非管理员）：payload 为空，实际拷贝由 postinstall 脚本完成，
  落位 ~/Library/Input Methods/ 与 ~/Applications/（与 manage-install.py 同位，
  两处并存语义一致）；
- pkg 只针对当前用户主目录（domains current-user-home），不请求管理员密码；
- 版本取 version.json 三段数字（pkg version 不接受预发布段），构建号进标题。

用法：python3 scripts/package-macos-pkg.py [--channel stable|dev]
前置：先跑 scripts/build.py（同通道）。输出 dist/Gogaku-<版本>-b<构建号>[-dev].pkg。
"""
import argparse
import hashlib
import json
import shutil
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
DIST = ROOT / 'dist'
LSREGISTER = ('/System/Library/Frameworks/CoreServices.framework/Frameworks/'
              'LaunchServices.framework/Support/lsregister')

CHANNELS = {
    'stable': {'input': 'Gogaku.app', 'settings': 'Gogaku Settings.app', 'suffix': '', 'label': 'Gogaku'},
    'dev': {'input': 'Gogaku Dev.app', 'settings': 'Gogaku Settings Dev.app', 'suffix': '-dev',
            'label': 'Gogaku Dev'},
}


def sha256(path: Path) -> str:
    h = hashlib.sha256()
    with open(path, 'rb') as f:
        for chunk in iter(lambda: f.read(1 << 20), b''):
            h.update(chunk)
    return h.hexdigest()


def postinstall_script(channel: dict) -> str:
    return f'''#!/bin/bash
# Gogaku pkg postinstall：把随包携带的双 App 放到当前用户目录并重新注册。
# 以安装进程身份运行（本 pkg 为用户级，不提权）；用户数据不受影响。
set -e
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
IM_DIR="$HOME/Library/Input Methods"
APPS_DIR="$HOME/Applications"
INPUT_APP="{channel['input']}"
SETTINGS_APP="{channel['settings']}"

# 若当前输入源正选着 Gogaku，提示但不阻断：旧进程继续用内存中的旧映像，
# 下次切换输入源时自然拉起新包（与 manage-install 的行为差异：pkg 不中断安装）。
if defaults read com.apple.HIToolbox AppleSelectedInputSources 2>/dev/null | grep -q org.gogaku.inputmethod; then
    echo "提示：当前输入源是 Gogaku。安装完成后请切换一次输入源以加载新版本。"
fi

rm -rf "$IM_DIR/$INPUT_APP" "$APPS_DIR/$SETTINGS_APP"
mkdir -p "$IM_DIR" "$APPS_DIR"
cp -R "$SCRIPT_DIR/$INPUT_APP" "$IM_DIR/$INPUT_APP"
cp -R "$SCRIPT_DIR/$SETTINGS_APP" "$APPS_DIR/$SETTINGS_APP"

# 重新注册 LaunchServices（移包重装会丢登记，否则系统不拉起输入法进程）。
{LSREGISTER} -f "$IM_DIR/$INPUT_APP" >/dev/null 2>&1 || true

echo "Gogaku 已安装：$IM_DIR/$INPUT_APP"
exit 0
'''


WELCOME_HTML = '''<html><head><meta charset="utf-8"><style>body{{font:13px/1.6 -apple-system,PingFang SC;margin:24px;color:#222}}</style></head>
<body><h2>Gogaku 输入法</h2>
<p><b>{label}</b>　{version}（构建号 {build}）</p>
<p>本安装器将把输入法装入 <code>~/Library/Input Methods/</code>，
设置应用装入 <code>~/Applications/</code>。不联网、不改系统输入源设置、
不触碰其他输入法；卸载即删这两个目录下的包。</p>
<p style="color:#666">建议安装前先切换到其他输入源（如 ABC）。</p></body></html>'''

README_HTML = '''<html><head><meta charset="utf-8"><style>body{{font:13px/1.6 -apple-system,PingFang SC;margin:24px;color:#222}}</style></head>
<body><h2>安装后一步：添加输入源</h2>
<ol>
<li>打开「系统设置 → 键盘 → 文本输入 → 输入法」点 <b>＋</b>；</li>
<li>在列表里选择 <b>{label}</b>（若无请注销重登一次）；</li>
<li>在菜单栏输入法菜单切换到 {label} 即可使用。</li>
</ol>
<p style="color:#666">本包未签名/未公证：首次打开若有「无法验证开发者」提示，
属无签名开发包的正常提示。学习数据位于
<code>~/Library/Application Support/Gogaku/</code>，升级与卸载默认保留。</p></body></html>'''


def run(cmd, **kw):
    print('+', ' '.join(str(c) for c in cmd))
    subprocess.run([str(c) for c in cmd], check=True, **kw)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--channel', choices=sorted(CHANNELS), default='stable')
    args = parser.parse_args()
    channel = CHANNELS[args.channel]

    meta = json.loads((ROOT / 'version.json').read_text())
    version_release = meta['version'].split('-', 1)[0]
    input_app = DIST / channel['input']
    settings_app = DIST / channel['settings']
    for app in (input_app, settings_app):
        if not app.exists():
            raise SystemExit(f'缺少 {app.relative_to(ROOT)}；先用 scripts/build.py'
                             f'{" --channel " + args.channel if args.channel != "stable" else ""} 构建')

    work = DIST / f'pkg-work{channel["suffix"]}'
    if work.exists():
        shutil.rmtree(work)
    (work / 'empty-payload').mkdir(parents=True)
    scripts = work / 'scripts'
    scripts.mkdir()
    subprocess.run(['cp', '-R', str(input_app), str(scripts / channel['input'])], check=True)
    subprocess.run(['cp', '-R', str(settings_app), str(scripts / channel['settings'])], check=True)
    post = scripts / 'postinstall'
    post.write_text(postinstall_script(channel))
    post.chmod(0o755)

    # 组件 pkg：空 payload（装到用户可写的 /private/tmp → 安装器不提权），
    # 真正的放位在 postinstall。脚本与 App 一起被打包，安装时展开到临时目录。
    core_pkg = work / f'gogaku-core{channel["suffix"]}.pkg'
    run(['pkgbuild', '--root', work / 'empty-payload',
         '--scripts', scripts,
         '--identifier', 'org.gogaku.inputmethod.pkg',
         '--version', version_release,
         '--install-location', '/private/tmp/gogaku-empty',
         core_pkg])

    res = work / 'resources'
    res.mkdir()
    fmt = dict(label=channel['label'], version=meta['version'], build=meta['buildNumber'])
    (res / 'welcome.html').write_text(WELCOME_HTML.format(**fmt))
    (res / 'readme.html').write_text(README_HTML.format(**fmt))

    # productbuild 手写 distribution 的 choice 结构会被静默丢弃组件包（实测
    # 输出 2KB 壳），必须用 --synthesize 生成基线再补丁：插入 domains（用户级
    # 不提权）＋welcome/readme＋标题。
    synth = work / 'distribution.xml'
    run(['productbuild', '--synthesize', '--package', core_pkg, synth])
    xml = synth.read_text()
    xml = xml.replace(
        '<installer-gui-script minSpecVersion="1">',
        '<installer-gui-script minSpecVersion="1">',
        1)
    # 标题
    xml = xml.replace(
        '<options',
        f'<title>{channel["label"]} {meta["version"]}（构建 {meta["buildNumber"]}）</title>\n'
        '    <welcome file="welcome.html" mime-type="text/html"/>\n'
        '    <readme file="readme.html" mime-type="text/html"/>\n'
        '    <domains enable_anywhere="false" enable_currentUserHome="true" '
        'enable_localSystem="false"/>\n    <options', 1)
    synth.write_text(xml)

    pkg_name = f"Gogaku-{meta['version']}-b{meta['buildNumber']}{channel['suffix']}.pkg"
    pkg_path = DIST / pkg_name
    if pkg_path.exists():
        pkg_path.unlink()
    run(['productbuild', '--distribution', synth,
         '--resources', res,
         '--package-path', work,
         '--identifier', 'org.gogaku.inputmethod',
         pkg_path])
    size_mb = pkg_path.stat().st_size / 1048576
    if size_mb < 10:
        # productbuild 曾静默产出无组件的空壳（见上）；不放过带病产物。
        raise SystemExit(f'pkg 异常：仅 {size_mb:.1f} MB（应为约 45+ MB），组件包未嵌入')
    shutil.rmtree(work)

    digest = sha256(pkg_path)
    (DIST / (pkg_name + '.sha256')).write_text(digest + '  ' + pkg_name + '\n')
    print(f'✅ PKG：{pkg_path}')
    print(f'   大小：{pkg_path.stat().st_size / 1048576:.1f} MB')
    print(f'   SHA-256：{digest}')
    print('安装方式：双击 pkg → 安装器向导 → 完成后在系统设置添加输入源。')


if __name__ == '__main__':
    main()
