#!/usr/bin/env python3
"""生成并签名 update-manifest.json（双端更新合同，见 docs/update.md）。

发布顺序必须让清单里的 assetId 指向真实 GitHub 资产：
1. `scripts/publish-release.py --dry-run` 检查本地资产与配置；
2. 创建 Draft Release，上传 pkg／setup；
3. 从上传响应取得 asset id；
4. 本脚本生成清单并用 Ed25519 私钥签名；
5. 上传 update-manifest.json 与 .sig，人工审阅后再发布 Release。

用法：
  python3 scripts/make-update-manifest.py --channel stable \
      --macos-pkg dist/Gogaku-0.1.2.pkg \
      --windows-setup dist/Gogaku-0.1.2-windows-x64-setup.exe \
      --asset-ids dist/update/asset-ids.json \
      --key ~/Library/Application Support/Gogaku/update-signing/prod-private-key.txt \
      --key-id gogaku-prod-2026

本地协议自测（不联网、临时密钥）：
  python3 scripts/make-update-manifest.py --self-test

双清单（2026-11 裁决）：每次运行生成两份清单——
- update-manifest[-lite].json（schema 1，只含主包）：0.2.0 及更早旧客户端
  继续读取，无数据包引用；
- update-manifest[-lite]-v2.json（schema 2，含 dataPackage）：新客户端优先
  拉取。schema 2 必须有 dataPackage；数据未变时用 --previous-state 复制上一
  版数据包资产引用（同一 dataVersion），数据变了则指向本轮数据包。
"""
from __future__ import annotations
import argparse
import hashlib
import json
import os
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
VERSION_FILE = ROOT / 'version.json'
SIGNER = ROOT / 'scripts/update-signing.swift'
PLATFORM_DEFAULTS = {
    'macos': {'arch': 'x86_64', 'minOS': '26.0', 'ext': '.pkg', 'label': 'macOS'},
    'windows': {'arch': 'x86_64', 'minOS': '10.0.22000', 'ext': '.exe', 'label': 'Windows'},
}


def fail(message):
    print(f'❌ {message}', file=sys.stderr)
    raise SystemExit(1)


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open('rb') as handle:
        for chunk in iter(lambda: handle.read(1 << 20), b''):
            digest.update(chunk)
    return digest.hexdigest()


def load_version():
    try:
        meta = json.loads(VERSION_FILE.read_text())
        return meta['version'], int(meta['buildNumber'])
    except (OSError, ValueError, KeyError, TypeError) as error:
        fail(f'无法读取 version.json：{error}')


def expected_name(platform: str, version: str, build: int, channel: str, product: str = 'full') -> str:
    # 对外文件名只用版本号＋通道后缀；构建号只用于内部对账（清单 buildNumber 字段），不进文件名。
    del build
    suffix = '-dev' if channel == 'dev' else ''
    prefix = 'GogakuLite' if product == 'lite' else 'Gogaku'
    if platform == 'macos':
        return f'{prefix}-{version}{suffix}.pkg'
    return f'{prefix}-{version}{suffix}-windows-x64-setup.exe'


def expected_data_name(platform: str, version: str, channel: str, product: str = 'full') -> str:
    """数据包资产名（本轮范围只有 macOS 有数据包；Windows 仍整包）。"""
    suffix = '-dev' if channel == 'dev' else ''
    prefix = 'GogakuLite' if product == 'lite' else 'Gogaku'
    if platform == 'macos':
        return f'{prefix}-Data-{version}{suffix}.pkg'
    raise ValueError(f'平台 {platform} 暂无数据包')


def load_previous_state(path: str | None) -> dict:
    """读上一版 release-state.json（复制数据包资产引用用）。容缺：文件缺失
    或没有数据包记录时返回空 dict，由调用方决定是否报错。"""
    if not path:
        return {}
    try:
        value = json.loads(Path(path).read_text())
        return value if isinstance(value, dict) else {}
    except (OSError, ValueError):
        return {}


def data_package_asset(platform: str, args, version: str, data_path: Path | None,
                       ids: dict, product: str) -> dict | None:
    """schema 2 的 dataPackage 对象。

    - 本轮数据包存在：用本轮资产的哈希／大小／ID 与数据收据里的 dataVersion。
    - 数据包缺失：若 --previous-state 的上一版记录有同产品数据包资产，复制
      该引用（dataVersion 未变——发布侧校验数据指纹一致后才允许这样做）。
    - 两者都没有：返回 None；publish-release.py 拒绝无 dataPackage 的 schema 2。"""
    if platform != 'macos':
        return None
    prefix = 'GogakuLite' if product == 'lite' else 'Gogaku'
    name_key = f'{prefix}-Data'
    if data_path is not None:
        receipt_path = Path(str(data_path) + '.receipt.json')
        try:
            receipt = json.loads(receipt_path.read_text())
        except (OSError, ValueError):
            fail(f'数据包收据缺失或不可读：{receipt_path}')
        if receipt.get('kind') != 'data-package' or not receipt.get('dataVersion'):
            fail(f'数据包收据必须是 data-package 且含 dataVersion：{receipt_path}')
        return {
            'platform': platform,
            'name': data_path.name,
            'size': data_path.stat().st_size,
            'sha256': sha256(data_path),
            'assetId': asset_id_for(ids, name_key, data_path.name, args.allow_placeholder_ids),
            'dataVersion': receipt['dataVersion'],
        }
    # 复制上一版引用：release-state.json 的 assets.dataPackage（publish 侧写入）。
    previous = load_previous_state(args.previous_state)
    record = (previous.get('assets', {}).get('dataPackage') or {})
    if record.get('name') and str(record.get('name', '')).startswith(name_key):
        print(f"提示：本轮无新数据包；复用上一版数据包引用 {record['name']}"
              f"（dataVersion {record.get('dataVersion')}）")
        return dict(record)
    return None


def manifest_basename(product: str) -> str:
    return 'update-manifest-lite.json' if product == 'lite' else 'update-manifest.json'


def load_asset_ids(path: Path | None) -> dict:
    if path is None:
        return {}
    try:
        data = json.loads(path.read_text())
    except (OSError, ValueError) as error:
        fail(f'无法读取 asset ids：{error}')
    if not isinstance(data, dict):
        fail('asset ids 必须是 JSON 对象')
    return data


def asset_id_for(ids: dict, platform: str, filename: str, allow_placeholder: bool) -> int:
    # 文件名优先：双产品（full + lite）共用一份 asset-ids 时，platform 键只能
    # 指向其中一个产品，按文件名取才不会把 Lite 清单绑到完整版资产上
    # （2026-11-16 实测：lite 清单的 macos assetId 指向了 full 的 pkg）。
    value = ids.get(filename, ids.get(platform))
    if isinstance(value, dict):
        value = value.get('id') or value.get('assetId')
    if value is None and allow_placeholder:
        return {'macos': 1, 'windows': 2}.get(platform, 1)
    if value is None:
        fail(f'缺少 {platform} 的 GitHub asset id；先上传 Draft 资产并生成 asset ids 文件')
    try:
        value = int(value)
    except (TypeError, ValueError):
        fail(f'{platform} asset id 不是整数：{value!r}')
    if value <= 0:
        fail(f'{platform} asset id 必须为正整数')
    return value


def build_manifest(args) -> tuple[dict, Path, Path | None]:
    """生成 schema 1（无数据包）与 schema 2（含 dataPackage）两份清单并签名。
    返回 (schema1清单, schema1签名, schema2清单, schema2签名) 的简化形式：
    schema1 必有；schema2 仅在能解析出 dataPackage 时生成（调用方缺数据包
    且无上一版引用时明确报错，而不是悄悄只发 schema1——那会让新客户端永远
    拿不到数据包）。"""
    version, build = load_version()
    if args.version:
        version = args.version
    if args.build:
        build = int(args.build)
    if build <= 0:
        fail('构建号必须为正整数')
    if args.channel == 'stable' and '-' in version:
        fail(f'stable 通道只接受正式版本；{version} 含预发布段')
    if args.channel == 'dev' and '-' not in version:
        # dev 通道允许正式版本（例如 dev 构建的正式版本号），但明确提示。
        print('提示：dev 通道的版本号不含预发布段；清单 channel 仍为 dev。')

    if args.notes_file:
        try:
            notes = Path(args.notes_file).read_text()
        except OSError as error:
            fail(f'无法读取发布说明：{error}')
    else:
        notes = f'Gogaku {version}（构建 {build}）。'
    if len(notes.encode('utf-8')) > 65536:
        fail('发布说明超过 64 KiB')

    ids = load_asset_ids(Path(args.asset_ids) if args.asset_ids else None)
    platforms = [p.strip() for p in args.platforms.split(',') if p.strip()]
    if not platforms:
        fail('--platforms 不能为空')
    for platform in platforms:
        if platform not in PLATFORM_DEFAULTS:
            fail(f'未知平台：{platform}')

    supplied = {'macos': args.macos_pkg, 'windows': args.windows_setup}
    data_supplied = {'macos': args.macos_data_pkg}
    assets = []
    for platform in platforms:
        path = supplied.get(platform)
        if not path:
            fail(f'缺少 {platform} 安装包路径')
        path = Path(path)
        if not path.is_file():
            fail(f'{platform} 安装包不存在：{path}')
        product = getattr(args, 'product', 'full')
        expected = expected_name(platform, version, build, args.channel, product)
        if args.require_names and path.name != expected:
            fail(f'{platform} 文件名应为 {expected}，实际 {path.name}')
        default = PLATFORM_DEFAULTS[platform]
        assets.append({
            'platform': platform,
            'arch': args.arch or default['arch'],
            'minOS': args.min_os if args.min_os and platform == 'macos' else default['minOS'],
            'assetId': asset_id_for(ids, platform, path.name, args.allow_placeholder_ids),
            'name': path.name,
            'size': path.stat().st_size,
            'sha256': sha256(path),
        })
    manifest = {
        'schema': 1,
        'keyId': args.key_id,
        'version': version,
        'buildNumber': build,
        'channel': args.channel,
        'notes': notes,
        'assets': assets,
    }

    # schema 2：主包 + dataPackage（本轮数据包或上一版引用）。
    product = getattr(args, 'product', 'full')
    data_path = Path(data_supplied['macos']) if data_supplied['macos'] else None
    if data_path is not None and not data_path.is_file():
        fail(f'macOS 数据包不存在：{data_path}')
    if data_path is not None and args.require_names:
        expected_data = expected_data_name('macos', version, args.channel, product)
        if data_path.name != expected_data:
            fail(f'macOS 数据包文件名应为 {expected_data}，实际 {data_path.name}')
    data_package = data_package_asset('macos', args, version, data_path, ids, product)
    manifest_v2 = dict(manifest)
    manifest_v2['schema'] = 2
    manifest_v2['dataPackage'] = data_package

    out_dir = Path(args.out or (ROOT / 'dist/update'))
    out_dir.mkdir(parents=True, exist_ok=True)
    base = manifest_basename(product)
    manifest_path = out_dir / base
    manifest_path.write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + '\n')
    signature_path = None
    manifest_v2_path = None
    signature_v2_path = None
    if not args.no_sign:
        signature_path = out_dir / (base + '.sig')
        sign(Path(args.key), args.key_id, manifest_path, signature_path)
    if data_package is not None:
        v2_base = base[:-len('.json')] + '-v2.json'
        manifest_v2_path = out_dir / v2_base
        manifest_v2_path.write_text(json.dumps(manifest_v2, ensure_ascii=False, indent=2) + '\n')
        if not args.no_sign:
            signature_v2_path = out_dir / (v2_base + '.sig')
            sign(Path(args.key), args.key_id, manifest_v2_path, signature_v2_path)
    else:
        fail('无法生成 schema 2 清单：既无本轮数据包，上一版状态也没有可复用的'
             '数据包引用（--previous-state）。主包清单已生成，但发布侧要求双清单。')
    print(f'✅ 清单：{manifest_path}')
    if manifest_v2_path:
        print(f'✅ schema 2 清单：{manifest_v2_path}')
    return manifest, manifest_path, signature_path


def sign(key_path: Path, key_id: str, manifest: Path, signature: Path) -> None:
    if not key_path or not Path(key_path).is_file():
        fail('缺少 Ed25519 私钥（--key）；私钥只存发布环境，不能入库')
    env = dict(os.environ)
    if Path('/Applications/Xcode.app/Contents/Developer').is_dir():
        env.setdefault('DEVELOPER_DIR', '/Applications/Xcode.app/Contents/Developer')
    result = subprocess.run(
        ['swift', str(SIGNER), 'sign', '--private', str(key_path),
         '--input', str(manifest), '--output', str(signature)],
        text=True, capture_output=True, env=env)
    if result.returncode != 0:
        fail(f'签名失败：{result.stderr.strip() or result.stdout.strip()}')
    # 如果随包配置里有同 keyId 的公钥，立即自验，避免把错误签名交给发布流程。
    config_path = ROOT / 'resources/update/config.json'
    try:
        config = json.loads(config_path.read_text())
        key = next((item for item in config.get('trustedKeys', [])
                    if item.get('keyId') == key_id), None)
    except (OSError, ValueError):
        key = None
    if key:
        verify = subprocess.run(
            ['swift', str(SIGNER), 'verify', '--public', key['publicKey'],
             '--input', str(manifest), '--sig', str(signature)],
            text=True, capture_output=True, env=env)
        if verify.returncode != 0:
            fail(f'签名自验失败：{verify.stderr.strip() or verify.stdout.strip()}')
    else:
        print('提示：随包配置中没有该 keyId 的公钥，跳过签名自验；发布前必须用生产公钥验证。')
    print(f'✅ 清单：{manifest}')
    print(f'   签名：{signature}')
    print(f'   keyId：{key_id}')


def self_test() -> None:
    with tempfile.TemporaryDirectory() as temporary:
        root = Path(temporary)
        pkg = root / 'Gogaku-0.1.2.pkg'
        setup = root / 'Gogaku-0.1.2-windows-x64-setup.exe'
        data = root / 'Gogaku-Data-0.1.2.pkg'
        pkg.write_bytes(b'fake-pkg-content' * 100)
        setup.write_bytes(b'fake-setup-content' * 100)
        data.write_bytes(b'fake-data-content' * 100)
        # 数据包收据（kind=data-package，含 dataVersion 指纹）。
        data_version = 'ab12cd34ef56ab12'
        (root / 'Gogaku-Data-0.1.2.pkg.receipt.json').write_text(json.dumps(
            {'kind': 'data-package', 'dataVersion': data_version}))
        key = root / 'private.txt'
        public_out = root / 'public.txt'
        env = dict(os.environ)
        if Path('/Applications/Xcode.app/Contents/Developer').is_dir():
            env.setdefault('DEVELOPER_DIR', '/Applications/Xcode.app/Contents/Developer')
        result = subprocess.run(
            ['swift', str(SIGNER), 'generate', '--private', str(key),
             '--public-out', str(public_out)],
            text=True, capture_output=True, env=env)
        if result.returncode != 0:
            fail(f'自测生成密钥失败：{result.stderr.strip()}')
        args = argparse.Namespace(
            channel='stable', version='0.1.2', build=90, notes_file=None,
            asset_ids=None, platforms='macos,windows', macos_pkg=str(pkg),
            macos_data_pkg=str(data), previous_state=None,
            windows_setup=str(setup), arch=None, min_os=None, key=str(key),
            key_id='self-test', out=str(root / 'out'), no_sign=False,
            allow_placeholder_ids=True, require_names=False)
        manifest, manifest_path, signature_path = build_manifest(args)
        assert manifest['buildNumber'] == 90
        assert len(manifest['assets']) == 2
        assert manifest['schema'] == 1
        for asset, source in zip(manifest['assets'], [pkg, setup]):
            assert asset['size'] == source.stat().st_size
            assert asset['sha256'] == sha256(source)
        # schema 2 双清单：v2 含 dataPackage，v1 不含。
        v2_path = root / 'out' / 'update-manifest-v2.json'
        assert v2_path.is_file(), 'schema 2 清单未生成'
        v2 = json.loads(v2_path.read_text())
        assert v2['schema'] == 2
        assert v2['dataPackage']['name'] == data.name
        assert v2['dataPackage']['dataVersion'] == data_version
        assert v2['dataPackage']['sha256'] == sha256(data)
        assert 'dataPackage' not in json.loads(manifest_path.read_text())
        # 数据未变：无本轮数据包时复用上一版 release-state 引用。
        previous_state = root / 'previous-state.json'
        previous_state.write_text(json.dumps({'assets': {'dataPackage': {
            'platform': 'macos', 'name': 'Gogaku-Data-0.1.1.pkg', 'size': 1234,
            'sha256': 'c' * 64, 'assetId': 99, 'dataVersion': data_version}}}))
        args.previous_state = str(previous_state)
        args.macos_data_pkg = None
        args.out = str(root / 'out2')
        _, v1_reuse_path, _ = build_manifest(args)
        v2_reuse = json.loads((root / 'out2' / 'update-manifest-v2.json').read_text())
        assert v2_reuse['dataPackage']['name'] == 'Gogaku-Data-0.1.1.pkg'
        assert v2_reuse['dataPackage']['assetId'] == 99
        # 既无数据包也无上一版引用：明确拒绝。
        args.previous_state = None
        args.out = str(root / 'out3')
        try:
            build_manifest(args)
            fail('无数据包时未拒绝 schema 2')
        except SystemExit:
            pass
        verify = subprocess.run(
            ['swift', str(SIGNER), 'verify', '--public',
             public_out.read_text().strip(), '--input', str(manifest_path),
             '--sig', str(signature_path)],
            text=True, capture_output=True, env=env)
        if verify.returncode != 0:
            fail(f'自测签名验证失败：{verify.stderr.strip()}')
        # 篡改清单必须验签失败。
        original = manifest_path.read_bytes()
        manifest_path.write_bytes(original + b' ')
        tampered = subprocess.run(
            ['swift', str(SIGNER), 'verify', '--public',
             public_out.read_text().strip(), '--input', str(manifest_path),
             '--sig', str(signature_path)],
            text=True, capture_output=True, env=env)
        if tampered.returncode == 0:
            fail('自测：篡改后的清单仍通过验签')
        manifest_path.write_bytes(original)
        print('✅ update-manifest self-test：生成、双清单、哈希、签名与篡改拒绝均通过')


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--self-test', action='store_true')
    parser.add_argument('--product', choices=['full', 'lite'], default='full',
                        help='完整版 update-manifest.json；Lite 用 update-manifest-lite.json')
    parser.add_argument('--channel', choices=['stable', 'dev'], default='stable')
    parser.add_argument('--version')
    parser.add_argument('--build', type=int)
    parser.add_argument('--notes-file')
    parser.add_argument('--macos-pkg')
    parser.add_argument('--macos-data-pkg', help='macOS 数据包（Gogaku-Data-<版本>.pkg）；schema 2 清单必需或可复用上一版引用')
    parser.add_argument('--previous-state', help='上一版 release-state.json；数据未变时复用其 dataPackage 资产引用')
    parser.add_argument('--windows-setup')
    parser.add_argument('--asset-ids')
    parser.add_argument('--platforms', default='macos,windows')
    parser.add_argument('--arch')
    parser.add_argument('--min-os', dest='min_os')
    parser.add_argument('--key')
    parser.add_argument('--key-id', default=os.environ.get('GOGAKU_UPDATE_KEY_ID', 'gogaku-dev-2026-11'))
    parser.add_argument('--out')
    parser.add_argument('--no-sign', action='store_true',
                        help='仅本地协议调试；正式发布必须签名')
    parser.add_argument('--allow-placeholder-ids', action='store_true',
                        help='仅自测；正式清单的 asset id 必须来自真实上传')
    parser.add_argument('--require-names', action='store_true', default=True)
    parser.add_argument('--no-require-names', dest='require_names', action='store_false')
    args = parser.parse_args()
    if args.self_test:
        self_test()
        return
    if args.no_sign and not args.allow_placeholder_ids:
        fail('--no-sign 只允许配合 --allow-placeholder-ids 做本地协议调试')
    build_manifest(args)


if __name__ == '__main__':
    main()
