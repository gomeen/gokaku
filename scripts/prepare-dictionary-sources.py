#!/usr/bin/env python3
"""下载并锁定扩展词库上游数据（docs/dictionaries.md §七；D5 发布侧第一步）。

用法：
  python3 scripts/prepare-dictionary-sources.py                # 下载＋校验（缺哈希则记录）
  python3 scripts/prepare-dictionary-sources.py --check        # 只校验，不写 sources.json
  python3 scripts/prepare-dictionary-sources.py --cache DIR    # 缓存目录（默认 .build/dict-sources）

行为：
- 逐条下载 resources/dictionaries/sources.json 里每个 upstream 的 downloadUrl，
  存入缓存目录（文件名＝sourceFileName）；
- 哈希已记录（sha256）则强校验；未记录则下载后回填 sources.json（锁定）；
- 出厂词典 sc.dict 用于转换（systemDict.path），缺失时明确失败（转换在
  build-dictionary-catalog.py 里做，本脚本只准备数据）。

许可红线见 docs/research-dictionaries.md §五：zhwiki／web-slang 数据为
Wikimedia CC BY-SA 4.0／GFDL（署名＋相同方式共享），THUOCL 为 MIT。
"""
from __future__ import annotations

import argparse
import hashlib
import json
import sys
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SOURCES = ROOT / 'resources' / 'dictionaries' / 'sources.json'


def fail(message: str) -> None:
    print(f'❌ {message}', file=sys.stderr)
    raise SystemExit(1)


def sha256_of(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open('rb') as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b''):
            digest.update(chunk)
    return digest.hexdigest()


def download(url: str, target: Path, limit: int = 512 * 1024 * 1024) -> None:
    request = urllib.request.Request(url, headers={'User-Agent': 'Gogaku dictionary build'})
    with urllib.request.urlopen(request, timeout=120) as response:  # noqa: S310（URL 来自入库锁定文件）
        data = response.read(limit + 1)
    if len(data) > limit:
        fail(f'{url} 超过大小上限')
    target.write_bytes(data)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--cache', default=str(ROOT / '.build' / 'dict-sources'))
    parser.add_argument('--check', action='store_true', help='只校验已有缓存与锁定哈希')
    args = parser.parse_args()

    sources = json.loads(SOURCES.read_text(encoding='utf-8'))
    cache = Path(args.cache)
    cache.mkdir(parents=True, exist_ok=True)

    dirty = False
    for upstream in sources.get('upstreams', []):
        name = upstream['sourceFileName']
        target = cache / name
        expected = upstream.get('sha256')
        if target.is_file() and expected:
            actual = sha256_of(target)
            if actual != expected:
                fail(f'{name} 缓存哈希不符（锁定 {expected[:12]}，实际 {actual[:12]}）')
            print(f'✔ {name}（缓存校验通过）')
            continue
        if target.is_file() and not expected:
            upstream['sha256'] = sha256_of(target)
            dirty = True
            print(f'🔒 {name} 已锁定 sha256 {upstream["sha256"][:12]}…')
            continue
        if args.check:
            fail(f'{name} 缓存缺失：{target}')
        print(f'↓ 下载 {name}（{upstream["upstream"]}）…')
        download(upstream['downloadUrl'], target)
        upstream['sha256'] = sha256_of(target)
        dirty = True
        print(f'🔒 {name} 已锁定 sha256 {upstream["sha256"][:12]}…')

    if dirty:
        SOURCES.write_text(json.dumps(sources, ensure_ascii=False, indent=2) + '\n',
                           encoding='utf-8')
        print('sources.json 已更新（版本与哈希锁定）。请人工审阅后随提交入库。')
    print('上游数据就绪。')


if __name__ == '__main__':
    main()
