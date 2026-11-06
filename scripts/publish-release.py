#!/usr/bin/env python3
"""双端发布：默认只创建 Draft，人工审阅后以同一 ID 续发。

两阶段均要求当前安装器收据和验证报告（--verification-report 可重复）。
  python3 scripts/publish-release.py --repo owner/releases --channel dev \
    --macos-pkg dist/example.pkg --windows-setup dist/example.exe \
    --verification-report dist/verify/report.json --key /private/key --key-id KEY
  # 人工审阅后，保留 out 目录中的清单、签名与 release-state.json：
  python3 scripts/publish-release.py ... --publish-existing RELEASE_ID

--publish 仅为 --publish-existing 的兼容开关，不能创建后立即发布。
--dry-run 执行全部本地门禁，不联网、不签名；续发的远端检查留待实际执行。
Token 只从 GITHUB_TOKEN 读取；失败日志不输出 HTTP 正文或子进程输出。
"""
from __future__ import annotations

import argparse
import base64
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import urllib.error
import urllib.parse
import urllib.request

from _gogaku_delivery import (DeliveryError, current_meta, read_json, sha256,
                              validate_package, validate_reports, write_json)

ROOT = Path(__file__).resolve().parent.parent
API = 'https://api.github.com'
UPLOADS = 'https://uploads.github.com'
DOWNLOAD_HOSTS = {'api.github.com', 'github.com', 'objects.githubusercontent.com',
                  'release-assets.githubusercontent.com', 'github-releases.githubusercontent.com'}
MANIFEST = 'update-manifest.json'
SIGNATURE = MANIFEST + '.sig'


def fail(message):
    print(f'发布拒绝：{message}', file=sys.stderr)
    raise SystemExit(1)


def expected_names(version: str, build: int, channel: str) -> dict:
    suffix = '-dev' if channel == 'dev' else ''
    return {
        'macos': f'Gogaku-{version}-b{build}{suffix}.pkg',
        'windows': f'Gogaku-{version}-b{build}{suffix}-windows-x64-setup.exe',
    }


def output_dir(args):
    return Path(args.out or ROOT / 'dist/update')


def state_path(args):
    return Path(args.release_state) if args.release_state else output_dir(args) / 'release-state.json'


def validate(args) -> dict:
    """任何网络操作、签名或 dry-run 成功之前都必须经过同一门禁。"""
    version = current_meta(ROOT)
    if args.version is not None and args.version != version['version']:
        fail('--version 不得覆盖 version.json')
    if args.build is not None and args.build != version['buildNumber']:
        fail('--build 不得覆盖 version.json')
    if args.publish and not args.publish_existing:
        fail('--publish 必须配合 --publish-existing RELEASE_ID；不能创建后直接发布')
    if args.publish_existing is not None and args.publish_existing <= 0:
        fail('--publish-existing 必须为正整数')
    if not re.fullmatch(r'[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+', args.repo or ''):
        fail('需要合法的 --repo owner/repo')
    names = expected_names(version['version'], version['buildNumber'], args.channel)
    assets = [('macos', Path(args.macos_pkg)), ('windows', Path(args.windows_setup))]
    packages = []
    for platform, path in assets:
        if args.require_names and path.name != names[platform]:
            fail(f'{platform} 文件名应为 {names[platform]}')
        packages.append(validate_package(path, platform, args.channel, root=ROOT))
    if any(packages[0][key] != packages[1][key]
           for key in ('fullVersion', 'buildNumber', 'sourceSha256', 'git')):
        fail('双端安装包必须来自相同源码／版本／Git 身份')
    if not args.verification_report:
        fail('至少需要一个 --verification-report')
    validate_reports(args.verification_report, packages, args.channel, root=ROOT)
    config = read_json(ROOT / 'resources/update/config.json')
    if f'{config.get("owner", "")}/{config.get("repo", "")}' != args.repo:
        fail('--repo 与随包更新源配置不符或更新源尚未配置')
    keys = [item for item in config.get('trustedKeys', []) if item.get('keyId') == args.key_id]
    if len(keys) != 1:
        fail('随包更新源配置必须包含唯一的受信任 keyId')
    try:
        if len(base64.b64decode(keys[0]['publicKey'], validate=True)) != 32:
            raise ValueError()
    except (ValueError, KeyError, TypeError):
        fail('受信任 Ed25519 公钥格式非法')
    if args.notes_file and len(Path(args.notes_file).read_bytes()) > 65536:
        fail('发布说明超过 64 KiB')
    if not args.publish_existing and not args.dry_run and not Path(args.key or '').is_file():
        fail('创建 Draft 需要 Ed25519 私钥：--key 或 GOGAKU_UPDATE_KEY')
    tag = args.tag or (f'v{version["version"]}-b{version["buildNumber"]}-dev'
                       if args.channel == 'dev' else f'v{version["version"]}')
    return {'version': version['version'], 'build': version['buildNumber'],
            'channel': args.channel, 'assets': assets, 'packages': packages,
            'sourceSha256': packages[0]['sourceSha256'], 'git': packages[0]['git'],
            'tag': tag, 'name': f'Gogaku {version["version"]}（构建 {version["buildNumber"]}）',
            'publicKey': keys[0]['publicKey']}


def safe_url(url, hosts):
    try:
        parsed = urllib.parse.urlsplit(url)
        valid = (parsed.scheme == 'https' and parsed.hostname in hosts
                 and parsed.port in (None, 443) and not parsed.username
                 and not parsed.password and not parsed.fragment)
    except ValueError:
        valid = False
    if not valid:
        fail('拒绝非 HTTPS 或非白名单主机 URL')


class SafeRedirect(urllib.request.HTTPRedirectHandler):
    def __init__(self, downloads=False):
        self.downloads = downloads

    def redirect_request(self, request, fp, code, msg, headers, newurl):
        if not self.downloads or request.get_method() != 'GET':
            fail('GitHub API 不允许重定向')
        safe_url(newurl, DOWNLOAD_HOSTS)
        redirected = super().redirect_request(request, fp, code, msg, headers, newurl)
        # urllib 默认会转发 Authorization；签名下载 URL 不需要这个 token。
        if redirected is not None:
            redirected.remove_header('Authorization')
            redirected.remove_header('Cookie')
        return redirected


def request_headers(token):
    return {'Authorization': f'Bearer {token}', 'Accept': 'application/vnd.github+json',
            'X-GitHub-Api-Version': '2022-11-28', 'User-Agent': 'Gogaku-release-script'}


def api_request(method: str, url: str, token: str, payload=None, data=None,
                content_type: str = 'application/json'):
    safe_url(url, {'api.github.com', 'uploads.github.com'})
    headers = request_headers(token)
    body = json.dumps(payload, ensure_ascii=False).encode() if payload is not None else data
    if body is not None:
        headers['Content-Type'] = content_type
    request = urllib.request.Request(url, data=body, method=method, headers=headers)
    try:
        with urllib.request.build_opener(SafeRedirect()).open(request, timeout=300) as response:
            raw = response.read()
            return json.loads(raw) if raw else {}
    except urllib.error.HTTPError as error:
        # 服务端正文、异常 URL／reason 可能回显凭据，不输出它们。
        fail(f'GitHub {method} 失败（HTTP {error.code}）')
    except (urllib.error.URLError, OSError, ValueError):
        fail(f'GitHub {method} 请求或响应失败')


def download_digest(repo, asset_id, token, expected_size):
    url = f'{API}/repos/{repo}/releases/assets/{asset_id}'
    headers = request_headers(token)
    headers['Accept'] = 'application/octet-stream'
    request = urllib.request.Request(url, headers=headers, method='GET')
    digest, size = hashlib.sha256(), 0
    try:
        with urllib.request.build_opener(SafeRedirect(downloads=True)).open(request, timeout=300) as response:
            safe_url(response.geturl(), DOWNLOAD_HOSTS)
            while True:
                chunk = response.read(min(1 << 20, expected_size - size + 1))
                if not chunk:
                    break
                size += len(chunk)
                if size > expected_size:
                    fail('远端资产下载大小超出本地收据')
                digest.update(chunk)
    except urllib.error.HTTPError as error:
        fail(f'GitHub 资产 GET 失败（HTTP {error.code}）')
    except (urllib.error.URLError, OSError):
        fail('GitHub 资产 GET 失败')
    if size != expected_size:
        fail('远端资产下载大小不符')
    return digest.hexdigest()


def upload_asset(repo: str, release_id: int, token: str, path: Path) -> int:
    url = f'{UPLOADS}/repos/{repo}/releases/{release_id}/assets?name={urllib.parse.quote(path.name)}'
    result = api_request('POST', url, token, data=path.read_bytes(), content_type='application/octet-stream')
    asset_id = result.get('id')
    if type(asset_id) is not int or asset_id <= 0:
        fail('上传后没有取得合法 asset id')
    print(f'上传 {path.name} -> asset {asset_id}')
    return asset_id


def run_manifest(args, asset_ids: Path) -> tuple[Path, Path]:
    command = [sys.executable, str(ROOT / 'scripts/make-update-manifest.py'),
               '--channel', args.channel, '--macos-pkg', str(args.macos_pkg),
               '--windows-setup', str(args.windows_setup), '--asset-ids', str(asset_ids),
               '--key', str(args.key), '--key-id', args.key_id, '--out', str(output_dir(args))]
    if args.notes_file:
        command += ['--notes-file', str(args.notes_file)]
    if not args.require_names:
        command += ['--no-require-names']
    result = subprocess.run(command, text=True, capture_output=True)
    if result.returncode != 0:
        fail('生成／签名清单失败（子进程输出已隐藏）')
    return output_dir(args) / MANIFEST, output_dir(args) / SIGNATURE


def file_record(path, asset_id):
    return {'id': asset_id, 'name': path.name, 'bytes': path.stat().st_size, 'sha256': sha256(path)}


def local_files(args, meta):
    return [path for _, path in meta['assets']] + [output_dir(args) / MANIFEST, output_dir(args) / SIGNATURE]


def binding(args, meta, release_id):
    return {'schema': 1, 'repo': args.repo, 'releaseId': release_id,
            'version': meta['version'], 'buildNumber': meta['build'], 'channel': args.channel,
            'sourceSha256': meta['sourceSha256'], 'git': meta['git'],
            'tag': meta['tag'], 'keyId': args.key_id}


def verify_manifest(args, meta, records):
    manifest, signature = output_dir(args) / MANIFEST, output_dir(args) / SIGNATURE
    if manifest.stat().st_size > 262144 or not 0 < signature.stat().st_size <= 8192:
        fail('清单或签名大小非法')
    value = read_json(manifest)
    if any(value.get(key) != expected for key, expected in {
            'schema': 1, 'keyId': args.key_id, 'version': meta['version'],
            'buildNumber': meta['build'], 'channel': args.channel}.items()):
        fail('签名清单与本轮版本／构建／通道不符')
    expected_assets = []
    for platform, path in meta['assets']:
        record = records[path.name]
        expected_assets.append({'platform': platform, 'arch': 'x86_64',
                                'minOS': '26.0' if platform == 'macos' else '10.0.22000',
                                'assetId': record['id'], 'name': path.name,
                                'size': record['bytes'], 'sha256': record['sha256']})
    if value.get('assets') != expected_assets:
        fail('签名清单未准确绑定双端本地安装包与已上传 asset IDs')
    env = dict(os.environ)
    if Path('/Applications/Xcode.app/Contents/Developer').is_dir():
        env.setdefault('DEVELOPER_DIR', '/Applications/Xcode.app/Contents/Developer')
    result = subprocess.run(['swift', str(ROOT / 'scripts/update-signing.swift'), 'verify',
                             '--public', meta['publicKey'], '--input', str(manifest),
                             '--sig', str(signature)], text=True, capture_output=True, env=env)
    if result.returncode:
        fail('清单 Ed25519 签名验证失败')


def validate_state(args, meta):
    state = read_json(state_path(args))
    if any(state.get(key) != value for key, value in binding(args, meta, args.publish_existing).items()):
        fail('release-state 与 repo／Release ID／源码／Git／版本／通道不符')
    records = state.get('assets', {})
    files = local_files(args, meta)
    if not isinstance(records, dict) or set(records) != {path.name for path in files} or len(records) != 4:
        fail('release-state 必须绑定且只绑定四个发布资产')
    ids = []
    for path in files:
        record = records[path.name]
        if not isinstance(record, dict) or type(record.get('id')) is not int or record['id'] <= 0:
            fail('release-state asset id 非法')
        if record != file_record(path, record['id']):
            fail('本地资产与 release-state 的大小／SHA-256 不符')
        ids.append(record['id'])
    if len(set(ids)) != 4:
        fail('release-state asset IDs 重复')
    verify_manifest(args, meta, records)
    return state


def validate_remote(args, meta, state, token):
    release_id = args.publish_existing
    url = f'{API}/repos/{args.repo}/releases/{release_id}'
    release = api_request('GET', url, token)
    if (release.get('id') != release_id or release.get('url') != url
            or release.get('draft') is not True
            or release.get('prerelease') is not (args.channel == 'dev')
            or release.get('tag_name') != state['tag'] or release.get('name') != meta['name']):
        fail('远端不是指定仓库中已审阅的同版本／构建／通道 Draft')
    # 显式取资产列表，不能相信 release 响应中可能截断的 assets。
    assets = api_request('GET', url + '/assets?per_page=100', token)
    if not isinstance(assets, list) or len(assets) != 4:
        fail('远端资产列表变化：必须恰好四项')
    expected = state['assets']
    if {asset.get('name') for asset in assets} != set(expected):
        fail('远端资产名称／列表变化')
    for asset in assets:
        record = expected[asset['name']]
        if (type(asset.get('id')) is not int or asset['id'] != record['id']
                or asset.get('size') != record['bytes'] or asset.get('state') != 'uploaded'):
            fail('远端资产 ID／大小／上传状态变化')
        digest = asset.get('digest')
        if digest is not None:
            if digest != 'sha256:' + record['sha256']:
                fail('远端资产 digest 不符')
        elif download_digest(args.repo, asset['id'], token, record['bytes']) != record['sha256']:
            fail('远端资产下载 SHA-256 不符')


def publish(args) -> None:
    meta = validate(args)
    state = validate_state(args, meta) if args.publish_existing else None
    if args.dry_run:
        print(f'DRY RUN：本地门禁通过，{meta["version"]}／b{meta["build"]}／{args.channel}')
        if state:
            print(f'计划 GET 核对 Draft {args.publish_existing} 及四个资产，再仅 PATCH 此 ID；尚未核对远端。')
        else:
            print(f'计划创建 Draft（tag={meta["tag"]}）；不自动发布。')
        return
    token = os.environ.get('GITHUB_TOKEN', '')
    if not token:
        fail('缺少 GITHUB_TOKEN（不要写在命令行或仓库里）')
    if state:
        validate_remote(args, meta, state, token)
        # 网络核对期间本地门禁或证据有变化，也不能发布。
        validate_state(args, validate(args))
        result = api_request('PATCH', f'{API}/repos/{args.repo}/releases/{args.publish_existing}',
                             token, payload={'draft': False})
        if result.get('id') != args.publish_existing or result.get('draft') is not False:
            fail('PATCH 未确认指定 Release 已发布；请人工核查，不自动重试')
        print(f'已发布 Release ID {args.publish_existing}')
        return
    if state_path(args).exists():
        fail('release-state 已存在；请续发该 Draft 或使用独立 --out 目录')
    body = Path(args.notes_file).read_text(encoding='utf-8') if args.notes_file else meta['name']
    release = api_request('POST', f'{API}/repos/{args.repo}/releases', token, payload={
        'tag_name': meta['tag'], 'name': meta['name'], 'body': body,
        'draft': True, 'prerelease': args.channel == 'dev'})
    release_id = release.get('id')
    if type(release_id) is not int or release_id <= 0 or release.get('draft') is not True:
        fail('创建 Draft 未返回合法 id／draft 状态')
    print(f'Draft Release ID {release_id}（任何后续失败都保留为 Draft）')
    out = output_dir(args)
    out.mkdir(parents=True, exist_ok=True)
    ids, records = {}, {}
    for platform, path in meta['assets']:
        asset_id = upload_asset(args.repo, release_id, token, path)
        ids[platform] = ids[path.name] = asset_id
        records[path.name] = file_record(path, asset_id)
    asset_ids_path = out / 'asset-ids.json'
    write_json(asset_ids_path, ids)
    run_manifest(args, asset_ids_path)
    verify_manifest(args, meta, records)
    for path in (out / MANIFEST, out / SIGNATURE):
        records[path.name] = file_record(path, upload_asset(args.repo, release_id, token, path))
    state = binding(args, meta, release_id)
    state['assets'] = records
    write_json(state_path(args), state)
    print(f'Draft 已就绪；保存 {state_path(args)} 及清单／签名，人工审阅后 --publish-existing {release_id}。')


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--repo', default=os.environ.get('GOGAKU_UPDATE_REPO', ''))
    parser.add_argument('--channel', choices=['stable', 'dev'], default='stable')
    parser.add_argument('--version')
    parser.add_argument('--build', type=int)
    parser.add_argument('--tag')
    parser.add_argument('--macos-pkg', required=True)
    parser.add_argument('--windows-setup', required=True)
    parser.add_argument('--verification-report', action='append', required=True)
    parser.add_argument('--notes-file')
    parser.add_argument('--key', default=os.environ.get('GOGAKU_UPDATE_KEY', ''))
    parser.add_argument('--key-id', default=os.environ.get('GOGAKU_UPDATE_KEY_ID', 'gogaku-prod-2026'))
    parser.add_argument('--out')
    parser.add_argument('--release-state', help='本地 Draft 收据；默认 <out>/release-state.json')
    parser.add_argument('--dry-run', action='store_true')
    parser.add_argument('--publish-existing', type=int, metavar='RELEASE_ID')
    parser.add_argument('--publish', action='store_true', help='只允许配合 --publish-existing，不能一次性直接发布')
    parser.add_argument('--require-names', action='store_true', default=True)
    parser.add_argument('--no-require-names', dest='require_names', action='store_false')
    args = parser.parse_args()
    try:
        publish(args)
    except (DeliveryError, OSError, ValueError, KeyError, TypeError) as error:
        # 只输出本地交付门禁错误；外部命令和 HTTP 错误已在边界处脱敏。
        if isinstance(error, DeliveryError):
            fail(str(error))
        fail('本地配置、资产或发布状态非法／不可读')


if __name__ == '__main__':
    main()
