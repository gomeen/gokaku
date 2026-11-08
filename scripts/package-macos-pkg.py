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
import os
import shutil
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
from _gogaku_delivery import (DeliveryError, package_receipt_path, validate_macos_apps,
                              write_package_receipt)
DIST = ROOT / 'dist'
LSREGISTER = ('/System/Library/Frameworks/CoreServices.framework/Frameworks/'
              'LaunchServices.framework/Support/lsregister')

CHANNELS = {
    'stable': {'input': 'Gogaku.app', 'settings': 'Gogaku Settings.app', 'suffix': '', 'label': 'Gogaku',
               'input_id': 'org.gogaku.inputmethod', 'settings_id': 'org.gogaku.settings'},
    'dev': {'input': 'Gogaku Dev.app', 'settings': 'Gogaku Settings Dev.app', 'suffix': '-dev',
            'label': 'Gogaku Dev', 'input_id': 'org.gogaku.inputmethod.dev',
            'settings_id': 'org.gogaku.settings.dev'},
}

POSTINSTALL_TEMPLATE = ROOT / 'macos/packaging/pkg-postinstall.sh'


def sha256(path: Path) -> str:
    h = hashlib.sha256()
    with open(path, 'rb') as f:
        for chunk in iter(lambda: f.read(1 << 20), b''):
            h.update(chunk)
    return h.hexdigest()


def available_identities() -> str:
    result = subprocess.run(['security', 'find-identity', '-v', '-p', 'codesigning'],
                            capture_output=True, text=True)
    return result.stdout + result.stderr


def require_identity(identity: str, label: str) -> None:
    if identity == '-':
        return
    if identity not in available_identities():
        raise SystemExit(
            f'找不到 {label} 签名身份：{identity}\n'
            '运行 `security find-identity -v -p codesigning` 查看可用身份；'
            '开发测试包可省略该选项使用 ad-hoc。')


def mach_o_files(app: Path) -> list[Path]:
    result = []
    for folder in ('Frameworks', 'Helpers', 'MacOS'):
        root = app / 'Contents' / folder
        if not root.exists():
            continue
        for path in root.rglob('*'):
            if not path.is_file():
                continue
            kind = subprocess.run(['file', '-b', str(path)], capture_output=True, text=True).stdout
            if 'Mach-O' in kind:
                result.append(path)
    # 先签最深的嵌套库／可执行，最后签 app 根。
    result.sort(key=lambda item: len(item.parts), reverse=True)
    return result


def sign_app(app: Path, identity: str) -> None:
    """对 app 内 Mach-O 由内向外签名，再签 app 根。

    Developer ID 签名必须保留到安装后：身份键在打包阶段注入，pkg postinstall
    不再重签，否则会把 Developer ID 签名降级成 ad-hoc，公证随之失效。
    """
    if identity == '-':
        subprocess.run(['codesign', '--force', '--deep', '--sign', '-', str(app)], check=True)
    else:
        for binary in mach_o_files(app):
            subprocess.run(['codesign', '--force', '--options', 'runtime', '--timestamp',
                            '--sign', identity, str(binary)], check=True)
        subprocess.run(['codesign', '--force', '--options', 'runtime', '--timestamp',
                        '--sign', identity, str(app)], check=True)
    subprocess.run(['codesign', '--verify', '--deep', '--strict', str(app)], check=True)


def postinstall_script(channel: dict, build: int) -> str:
    """事务式 postinstall（模板见 macos/packaging/pkg-postinstall.sh）。

    为什么 App 以 zip 随包而非直接放 Scripts 目录：安装器会把 Scripts 展开
    到 PKInstallSandboxManager 沙箱，LaunchServices 会扫描其中的 .app 并注册
    ——安装结束后沙箱路径失效，输入法列表里就留下指向死路径的幽灵条目
    （2026-11-06 实测）。zip 里的 .app 不会被扫描；解包校验后再替换。
    """
    template = POSTINSTALL_TEMPLATE.read_text()
    return (template.replace('@INPUT_APP@', channel['input'])
            .replace('@SETTINGS_APP@', channel['settings'])
            .replace('@INPUT_ID@', channel['input_id'])
            .replace('@SETTINGS_ID@', channel['settings_id'])
            .replace('@BUILD@', str(build)))


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
<p style="color:#666">{signature_note}</p>
<p style="color:#666">学习数据位于
<code>~/Library/Application Support/Gogaku/</code>，升级与卸载默认保留。</p></body></html>'''

CONCLUSION_HTML = '''<html><head><meta charset="utf-8"><style>body{{font:13px/1.6 -apple-system,PingFang SC;margin:24px;color:#222}}</style></head>
<body><h2>安装完成</h2>
<p><b>{label}</b> 已装入当前用户目录。</p>
<ol>
<li>打开「系统设置 → 键盘 → 文本输入 → 输入法」点 <b>＋</b>，添加 <b>{label}</b>；</li>
<li>从菜单栏输入法菜单切换到 {label}；</li>
<li>打开「{label} 设置」可配置普通输入、学习翻译与检查更新。</li>
</ol>
<p style="color:#666">{signature_note}</p>
<p style="color:#666">不需要重启，也不会修改默认输入法。若输入源列表未出现，注销并重新登录一次即可。</p></body></html>'''


def run(cmd, **kw):
    print('+', ' '.join(str(c) for c in cmd))
    subprocess.run([str(c) for c in cmd], check=True, **kw)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--channel', choices=sorted(CHANNELS), default='stable')
    parser.add_argument('--app-sign-identity', default=os.environ.get('GOGAKU_APP_SIGN_IDENTITY', '-'),
                        help='Developer ID Application 身份；省略＝ad-hoc（开发测试）')
    parser.add_argument('--installer-sign-identity', default=os.environ.get('GOGAKU_INSTALLER_SIGN_IDENTITY', ''),
                        help='Developer ID Installer 身份；省略＝不签 pkg')
    parser.add_argument('--notarize', action='store_true',
                        help='提交 Apple 公证并 stapling；需要 Developer ID 与 --notary-profile')
    parser.add_argument('--notary-profile', default=os.environ.get('GOGAKU_NOTARY_PROFILE', ''),
                        help='notarytool keychain profile 名')
    args = parser.parse_args()
    channel = CHANNELS[args.channel]
    if args.app_sign_identity != '-':
        require_identity(args.app_sign_identity, 'Developer ID Application')
    if args.installer_sign_identity:
        require_identity(args.installer_sign_identity, 'Developer ID Installer')
    if args.notarize:
        if not args.installer_sign_identity or args.app_sign_identity == '-':
            raise SystemExit('--notarize 需要同时提供 --app-sign-identity 与 --installer-sign-identity')
        if not args.notary_profile:
            raise SystemExit('--notarize 需要 --notary-profile（或 GOGAKU_NOTARY_PROFILE）')
    if args.notarize:
        signature_note = '本包已使用 Developer ID 签名并完成 Apple 公证。'
    elif args.installer_sign_identity:
        signature_note = '本包已使用 Developer ID 签名；未提交 Apple 公证。'
    else:
        signature_note = ('本包未签名/未公证（开发测试）。若系统提示「无法验证开发者」，'
                          '请右键打开或到系统设置允许；正式分发需 Developer ID 与公证。')

    meta = json.loads((ROOT / 'version.json').read_text())
    build_identity = validate_macos_apps(DIST, args.channel, root=ROOT)
    identity_path = DIST / ('build-identity-dev.json' if args.channel == 'dev' else 'build-identity.json')
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
    # 在打包阶段注入输入源身份并签名（Developer ID 或 ad-hoc），再打成 zip。
    # zip 内的 .app 不会被 LaunchServices 扫描；安装时只解包，不再重签，
    # 因此 Developer ID 签名与公证能保留到安装后。dist 仍保持中立。
    import sys
    sys.path.insert(0, str(Path(__file__).resolve().parent))
    from _gogaku_dist import apply_tis_identity, deterministic_plist_bytes
    import plistlib
    staging = work / 'apps'
    staging.mkdir()
    for source, name, identifier in [
            (input_app, channel['input'], channel['input_id']),
            (settings_app, channel['settings'], channel['settings_id'])]:
        staged = staging / name
        shutil.copytree(source, staged, symlinks=True)
        info = plistlib.loads((staged / 'Contents/Info.plist').read_bytes())
        if info.get('CFBundleIdentifier') != identifier:
            raise SystemExit(f'{source.name} 身份不符：{info.get("CFBundleIdentifier")} ≠ {identifier}')
        if identifier.startswith('org.gogaku.inputmethod'):
            (staged / 'Contents/Info.plist').write_bytes(
                deterministic_plist_bytes(apply_tis_identity(info, identifier)))
        sign_app(staged, args.app_sign_identity)
    run(['zip', '-q', '-r', scripts / 'Gogaku-apps.zip',
         channel['input'], channel['settings']], cwd=staging)
    post = scripts / 'postinstall'
    post.write_text(postinstall_script(channel, meta['buildNumber']))
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
    fmt = dict(label=channel['label'], version=meta['version'], build=meta['buildNumber'],
               signature_note=signature_note)
    (res / 'welcome.html').write_text(WELCOME_HTML.format(**fmt))
    (res / 'readme.html').write_text(README_HTML.format(**fmt))
    (res / 'conclusion.html').write_text(CONCLUSION_HTML.format(**fmt))

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
        '    <conclusion file="conclusion.html" mime-type="text/html"/>\n'
        '    <domains enable_anywhere="false" enable_currentUserHome="true" '
        'enable_localSystem="false"/>\n    <options', 1)
    synth.write_text(xml)

    pkg_name = f"Gogaku-{meta['version']}-b{meta['buildNumber']}{channel['suffix']}.pkg"
    pkg_path = DIST / pkg_name
    if pkg_path.exists():
        pkg_path.unlink()
    package_receipt_path(pkg_path).unlink(missing_ok=True)
    productbuild = ['productbuild', '--distribution', synth,
                    '--resources', res,
                    '--package-path', work,
                    '--identifier', 'org.gogaku.inputmethod']
    if args.installer_sign_identity:
        productbuild += ['--sign', args.installer_sign_identity]
    productbuild.append(pkg_path)
    run(productbuild)
    size_mb = pkg_path.stat().st_size / 1048576
    if size_mb < 10:
        # productbuild 曾静默产出无组件的空壳（见上）；不放过带病产物。
        raise SystemExit(f'pkg 异常：仅 {size_mb:.1f} MB（应为约 45+ MB），组件包未嵌入')
    if args.installer_sign_identity:
        run(['pkgutil', '--check-signature', pkg_path])
    if args.notarize:
        run(['xcrun', 'notarytool', 'submit', pkg_path,
             '--keychain-profile', args.notary_profile, '--wait'])
        run(['xcrun', 'stapler', 'staple', pkg_path])
        run(['xcrun', 'stapler', 'validate', pkg_path])
        # 公证后 Gatekeeper 的安装评估必须通过；失败不交付。
        run(['spctl', '-a', '-vv', '-t', 'install', pkg_path])
    shutil.rmtree(work)

    # 卫生：dist 内的 .app 会被 LaunchServices 周期扫描重新注册成输入源幽灵
    # （同 ID 遮蔽真身）。产物打包完即注销；build.py 构建尾同理。
    for app in (input_app, settings_app):
        subprocess.run([LSREGISTER, '-u', str(app)], capture_output=True)

    # 拒绝组装过程中源码或 dist 输入变化；收据只为本轮验证过的包生成。
    if validate_macos_apps(DIST, args.channel, root=ROOT) != build_identity:
        raise DeliveryError('打包期间双 App 身份变化；请重新构建')
    license_files = [f'{name}/{relative}' for name, entry in build_identity['apps'].items()
                     for relative in entry['files'] if relative.startswith('Contents/Licenses/')]
    receipt_path = write_package_receipt(pkg_path, 'macos', args.channel, build_identity,
                                         identity_path, license_files, root=ROOT)
    digest = sha256(pkg_path)
    (DIST / (pkg_name + '.sha256')).write_text(digest + '  ' + pkg_name + '\n')
    print(f'   构建收据：{receipt_path}')
    print(f'✅ PKG：{pkg_path}')
    print(f'   大小：{pkg_path.stat().st_size / 1048576:.1f} MB')
    print(f'   SHA-256：{digest}')
    print(f'   签名：{signature_note}')
    print('安装方式：双击 pkg → 安装器向导 → 完成后在系统设置添加输入源。')


if __name__ == '__main__':
    try:
        main()
    except DeliveryError as error:
        raise SystemExit(f'Mac 打包失败：{error}') from error
