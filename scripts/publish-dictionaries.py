#!/usr/bin/env python3
"""发布官方词库到 gomeen/gogaku-dicts（docs/dictionaries.md §七；D5 发布侧第三步）。

用法：
  # 全程演练（只校验与确定性构建检查，不联网）：
  python3 scripts/publish-dictionaries.py --dry-run \
      --catalog dist/dict-catalog/catalog.json --dir dist/dict-catalog

  # 真实发布：先建 Draft（上传 13 本 .dict ＋ catalog.json ＋ .sig ＋ 发布说明），
  # 人工审阅后在 GitHub 界面发布（stable 只接受正式 Release 的口径同样适用）：
  GITHUB_TOKEN=… python3 scripts/publish-dictionaries.py \
      --catalog dist/dict-catalog/catalog.json --dir dist/dict-catalog

前置（需要用户提供，见 docs/dictionaries.md §阶段）：
- 公开仓库 gomeen/gogaku-dicts 已创建；
- GITHUB_TOKEN 具备该仓库 Release 写权限；
- catalog.json 已用发布环境私钥签名（build-dictionary-catalog.py）。

安全口径：Token 只从环境变量读取，失败日志不回显正文或凭据；downloadUrl 的
主机白名单与检查更新一致（github.com／objects.githubusercontent.com 等）。
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import subprocess
import sys
import urllib.error
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
API = 'https://api.github.com'
DEFAULT_REPO = 'gomeen/gogaku-dicts'


def fail(message: str) -> None:
    print(f'❌ {message}', file=sys.stderr)
    raise SystemExit(1)


def sha256_of(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open('rb') as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b''):
            digest.update(chunk)
    return digest.hexdigest()


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


def api_request(method: str, url: str, token: str, payload=None, allow_missing=False):
    if not url.startswith(API + '/repos/'):
        fail('拒绝非 GitHub API 地址')
    headers = {'Accept': 'application/vnd.github+json',
               'X-GitHub-Api-Version': '2022-11-28',
               'Authorization': f'Bearer {token}'}
    body = json.dumps(payload, ensure_ascii=False).encode() if payload is not None else None
    if body is not None:
        headers['Content-Type'] = 'application/json'
    request = urllib.request.Request(url, data=body, method=method, headers=headers)
    try:
        with urllib.request.build_opener(NoRedirect()).open(request, timeout=300) as response:
            raw = response.read()
            return json.loads(raw) if raw else {}
    except urllib.error.HTTPError as error:
        if allow_missing and error.code == 404:
            return None
        # 服务端正文可能回显凭据或内部信息，一律不输出。
        fail(f'GitHub {method} 失败（HTTP {error.code}）')
    except (urllib.error.URLError, OSError, ValueError):
        fail('GitHub 请求或响应失败')


def upload_asset(upload_url: str, token: str, path: Path, name: str) -> dict:
    base = upload_url.split('{', 1)[0]
    if not base.startswith('https://uploads.github.com/'):
        fail('上传地址不在 uploads.github.com')
    url = f'{base}?name={name}'
    headers = {'Authorization': f'Bearer {token}', 'Content-Type': 'application/octet-stream'}
    request = urllib.request.Request(url, data=path.read_bytes(), method='POST', headers=headers)
    try:
        with urllib.request.build_opener(NoRedirect()).open(request, timeout=600) as response:
            return json.loads(response.read())
    except urllib.error.HTTPError as error:
        fail(f'上传 {name} 失败（HTTP {error.code}）')
    except (urllib.error.URLError, OSError):
        fail(f'上传 {name} 失败')


def validate_catalog(catalog_path: Path) -> dict:
    catalog = json.loads(catalog_path.read_text(encoding='utf-8'))
    if catalog.get('kind') != 'gogaku-dictionary-catalog':
        fail('catalog.json kind 不符')
    if catalog.get('schemaVersion') != 1:
        fail('catalog.json schema 不支持')
    if not isinstance(catalog.get('catalogVersion'), int) or catalog['catalogVersion'] < 1:
        fail('catalogVersion 非法')
    if not isinstance(catalog.get('dictionaries'), list) or not catalog['dictionaries']:
        fail('dictionaries 为空')
    ids = set()
    for entry in catalog['dictionaries']:
        entry_id = entry.get('id', '')
        if not re.fullmatch(r'[a-z0-9-]{1,64}', entry_id) or entry_id in ids:
            fail(f'id 非法或重复：{entry_id}')
        ids.add(entry_id)
        url = entry.get('downloadUrl', '')
        prefix = f'https://github.com/{DEFAULT_REPO}/releases/download/'
        if not url.startswith(prefix) or '..' in url:
            fail(f'{entry_id} downloadUrl 越界')
        if entry.get('size', 0) <= 0 or len(entry.get('sha256', '')) != 64:
            fail(f'{entry_id} size/sha256 非法')
    return catalog


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--catalog', default=str(ROOT / 'dist/dict-catalog/catalog.json'))
    parser.add_argument('--dir', default=str(ROOT / 'dist/dict-catalog'))
    parser.add_argument('--repo', default=DEFAULT_REPO)
    parser.add_argument('--dry-run', action='store_true')
    parser.add_argument('--test-public-key', help='仅在 dry-run 使用测试公钥')
    args = parser.parse_args()

    catalog_path = Path(args.catalog)
    directory = Path(args.dir)
    if not catalog_path.is_file():
        fail(f'缺少 {catalog_path}；先运行 build-dictionary-catalog.py')
    signature = catalog_path.with_suffix('.json.sig')
    if not signature.is_file():
        fail('缺少 catalog.json.sig（清单必须先签名）')
    catalog = validate_catalog(catalog_path)
    if args.repo != DEFAULT_REPO or (args.test_public_key and not args.dry_run):
        fail('正式发布只接受配置中的词库仓库和生产签名')
    settings = json.loads((ROOT / 'resources/update/config.json').read_text())
    config = json.loads((ROOT / 'resources/dictionaries/catalog-config.json').read_text())
    key_id = catalog.get('keyId')
    trusted = next((k['publicKey'] for k in settings['trustedKeys']
                    if k['keyId'] == key_id and key_id in config['trustedKeyIds']), None)
    public_key = args.test_public_key or trusted
    if not public_key:
        fail('清单签名 keyId 不受信任')
    verified = subprocess.run(['swift', str(ROOT / 'scripts/update-signing.swift'), 'verify',
                               '--public', public_key, '--input', str(catalog_path),
                               '--sig', str(signature)], capture_output=True)
    if verified.returncode:
        fail('清单签名验证失败')
    if not (directory / 'release-notes.md').is_file():
        fail('缺少 release-notes.md（发布说明须写明每本的丢弃计数）')
    licenses = ['THUOCL-LICENSE.txt', 'CC-BY-SA-4.0.txt']
    for name in licenses:
        if not (directory / name).is_file() or (directory / name).stat().st_size == 0:
            fail(f'缺少许可附件 {name}')

    # 确定性构建检查：资产哈希与清单一致。
    for entry in catalog['dictionaries']:
        asset = directory / (entry['id'] + '.dict')
        if not asset.is_file():
            fail(f'资产缺失：{asset}')
        if sha256_of(asset) != entry['sha256'] or asset.stat().st_size != entry['size']:
            fail(f'{entry["id"]} 资产与清单不符（sha256／size）')

    tag = f'catalog-{catalog["catalogVersion"]}'
    print(f'✔ 本地校验通过：{len(catalog["dictionaries"])} 本资产、清单与签名齐备（tag {tag}）')

    if args.dry_run:
        print('dry-run 通过；未联网、未创建 Release。正式发布去掉 --dry-run 并提供 GITHUB_TOKEN。')
        return

    token = os.environ.get('GITHUB_TOKEN', '')
    if not token:
        fail('缺少 GITHUB_TOKEN（不要写在命令行或仓库里）')

    repository = api_request('GET', f'{API}/repos/{args.repo}', token)
    if repository.get('private', True):
        fail('词库发布仓库必须公开')
    existing = api_request('GET', f'{API}/repos/{args.repo}/releases/tags/{tag}', token, allow_missing=True)
    if existing is not None:
        fail(f'{tag} 已存在（Release {existing.get("id")}）')
    latest = api_request('GET', f'{API}/repos/{args.repo}/releases/latest', token, allow_missing=True)
    if latest is not None:
        prior = re.fullmatch(r'catalog-(\d+)', latest.get('tag_name', ''))
        if not prior or int(prior[1]) >= catalog['catalogVersion']:
            fail('catalogVersion 必须高于当前发布版本')

    release = api_request('POST', f'{API}/repos/{args.repo}/releases', token, payload={
        'tag_name': tag,
        'name': tag,
        'body': (directory / 'release-notes.md').read_text(encoding='utf-8'),
        'draft': True,
        'prerelease': False,
    })
    print(f'✔ Draft 已创建：Release {release["id"]}（{tag}）')

    for path, name in [
        (catalog_path, 'catalog.json'),
        (signature, 'catalog.json.sig'),
        *[(directory / name, name) for name in licenses],
        *[(directory / (entry['id'] + '.dict'), entry['id'] + '.dict')
          for entry in catalog['dictionaries']],
    ]:
        asset = upload_asset(release['upload_url'], token, path, name)
        print(f'✔ 已上传 {name}（asset {asset.get("id")}）')

    print('⚠️ Draft 已就绪但尚未发布。人工审阅资产与发布说明后再在 GitHub 界面发布。')
    print('发布记录须写明每本的丢弃计数（见 release-notes.md）。')


if __name__ == '__main__':
    main()
