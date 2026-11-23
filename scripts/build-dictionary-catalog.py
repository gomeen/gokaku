#!/usr/bin/env python3
"""构建并签名官方词库清单 catalog.json（docs/dictionaries.md §七；D5 发布侧第二步）。

用法：
  python3 scripts/build-dictionary-catalog.py --catalog-version 1 \
      --key ~/Library/Application\\ Support/Gogaku/update-signing/prod-private-key.txt \
      --key-id gogaku-prod-2026-11 \
      --out dist/dict-catalog

行为：
1. 读 resources/dictionaries/sources.json（上游锁定）与缓存（先跑
   prepare-dictionary-sources.py）；
2. 对每本词库调用 gogaku_dict_tool convert（与设置应用导入共用同一份核心
   转换实现）产出 libime 二进制 .dict 与转换报告（entryCount／dropped）；
3. 计算 .dict 的 SHA-256 与大小，生成 catalog.json（schema 1、kind
   "gogaku-dictionary-catalog"、keyId、单调递增 catalogVersion）；
   每本使用数字修订，零条目来源只保留报告与署名；
4. 用 Ed25519 私钥签名（复用 scripts/update-signing.swift 与发布环境密钥），
   产出 catalog.json.sig；
5. `--verify-only` 重跑转换并逐字节比对（两次构建产出必须一致）。

发布顺序：prepare-dictionary-sources.py → build-dictionary-catalog.py →
publish-dictionaries.py（先 Draft，人工审阅后发布）。发布记录须写明每本的
丢弃计数（转换报告）。
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SOURCES = ROOT / 'resources' / 'dictionaries' / 'sources.json'
SIGNER = ROOT / 'scripts/update-signing.swift'
TOOL = ROOT / '.build/core/gogaku_dict_tool'


def fail(message: str) -> None:
    print(f'❌ {message}', file=sys.stderr)
    raise SystemExit(1)


def sha256_of(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open('rb') as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b''):
            digest.update(chunk)
    return digest.hexdigest()


def convert(source: Path, system_dict: Path, work: Path, output: Path,
            name: str) -> dict:
    """走 gogaku_dict_tool convert（与设置应用导入同一份核心实现）。"""
    if not TOOL.is_file():
        fail(f'缺少 {TOOL}；先构建共享核心（cmake --build .build/core --target gogaku_dict_tool）')
    if output.exists():
        output.unlink()
    work.mkdir(parents=True, exist_ok=True)
    report = work / (output.stem + '-report.json')
    with tempfile.TemporaryDirectory(dir=work) as temporary:
        result = subprocess.run(
            [str(TOOL), 'convert', '--input', str(source), '--system-dict', str(system_dict),
             '--name', name, '--work', temporary, '--output', str(output), '--report', str(report)],
            capture_output=True, text=True)
    if result.returncode != 0:
        fail(f'{source.name} 转换失败（{result.returncode}）：{result.stderr.strip() or result.stdout.strip()}')
    data = json.loads(report.read_text(encoding='utf-8'))
    return data


def sign(key_path: Path, key_id: str, manifest: Path, signature: Path) -> None:
    if not key_path.is_file():
        fail(f'缺少 Ed25519 私钥（--key {key_path}）；私钥只存发布环境，不能入库')
    env = dict(os.environ)
    if Path('/Applications/Xcode.app/Contents/Developer').is_dir():
        env.setdefault('DEVELOPER_DIR', '/Applications/Xcode.app/Contents/Developer')
    result = subprocess.run(
        ['swift', str(SIGNER), 'sign', '--private', str(key_path),
         '--input', str(manifest), '--output', str(signature)],
        text=True, capture_output=True, env=env)
    if result.returncode != 0:
        fail(f'签名失败：{result.stderr.strip() or result.stdout.strip()}')
    # 若随包配置里有同 keyId 的公钥，立即自验，避免把错误签名交给发布流程。
    config_path = ROOT / 'resources' / 'update' / 'config.json'
    try:
        config = json.loads(config_path.read_text())
        public_key = next((k['publicKey'] for k in config.get('trustedKeys', [])
                           if k.get('keyId') == key_id), None)
    except (OSError, ValueError, KeyError, StopIteration):
        public_key = None
    if public_key:
        check = subprocess.run(
            ['swift', str(SIGNER), 'verify', '--public', public_key,
             '--input', str(manifest), '--sig', str(signature)],
            text=True, capture_output=True, env=env)
        if check.returncode != 0:
            fail(f'签名自验失败：{check.stderr.strip() or check.stdout.strip()}')
        print('✔ 签名已用随包公钥自验（与检查更新同一信任链）')
    else:
        print('⚠️ 随包配置无此 keyId 公钥；跳过本地自验（发布前必须人工核对 keyId）')


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--catalog-version', type=int, required=True,
                        help='单调递增的 catalogVersion；不得小于已发布版本')
    parser.add_argument('--key', default=str(Path.home() / 'Library/Application Support/Gogaku/update-signing/prod-private-key.txt'))
    parser.add_argument('--key-id', default='gogaku-prod-2026-11')
    parser.add_argument('--out', default=str(ROOT / 'dist' / 'dict-catalog'))
    parser.add_argument('--cache', default=str(ROOT / '.build' / 'dict-sources'))
    parser.add_argument('--verify-only', action='store_true',
                        help='重跑转换并逐字节比对现有输出（确定性构建检查）')
    parser.add_argument('--unsigned', action='store_true', help='仅生成本地验收资产')
    args = parser.parse_args()
    if args.catalog_version < 1:
        fail('catalogVersion 必须为正整数')

    sources = json.loads(SOURCES.read_text(encoding='utf-8'))
    upstreams = sources['upstreams']
    for upstream in upstreams:
        revision = upstream.get('revision')
        if type(revision) is not int or not 1 <= revision <= 2**63 - 1:
            fail(f'{upstream["id"]} revision 必须为正整数（不超过 int64 上限）')
        if not isinstance(upstream.get('upstreamRevision'), str) or not upstream['upstreamRevision'].strip():
            fail(f'{upstream["id"]} 缺少 upstreamRevision')
    cache = Path(args.cache)
    out = Path(args.out)
    out.mkdir(parents=True, exist_ok=True)
    system_dict = Path(sources.get('systemDict', {}).get('path', '')).expanduser()
    if not system_dict.is_file():
        fail(f'出厂词典缺失：{system_dict}（转换去重与读音推断的基准）')

    entries = []
    conversions = []
    tag = f'catalog-{args.catalog_version}'
    for upstream in upstreams:
        name = upstream['sourceFileName']
        source = cache / name
        expected = upstream.get('sha256')
        if not source.is_file():
            fail(f'{name} 缓存缺失；先运行 prepare-dictionary-sources.py')
        actual = sha256_of(source)
        if not expected or actual != expected:
            fail(f'{name} 缓存哈希缺失或不符')
        target = out / (upstream['id'] + '.dict')
        if args.verify_only:
            with tempfile.TemporaryDirectory() as temporary:
                trial = Path(temporary) / target.name
                report = convert(source, system_dict, Path(temporary), trial, upstream['name'])
                if report['entryCount'] == 0:
                    if target.exists():
                        fail(f'{target.name} 是空词库，不应作为资产存在')
                    print(f'✔ {target.name} 再次转换为零条目，未上架')
                else:
                    if not target.is_file() or sha256_of(target) != sha256_of(trial):
                        fail(f'{target.name} 两次构建不一致')
                    print(f'✔ {target.name} 两次构建字节一致')
            continue
        report = convert(source, system_dict, out / 'work', target, upstream['name'])
        count = report['entryCount']
        conversions.append((upstream, report))
        if count == 0:
            target.unlink()
            print(f'注意：{name} 的条目全部被过滤，不上架，详见转换报告。', file=sys.stderr)
            continue
        entries.append({
            'id': upstream['id'],
            'name': upstream['name'],
            'category': upstream['category'],
            'description': upstream['description'],
            'version': str(upstream['revision']),
            'license': upstream['license'],
            'attribution': upstream['attribution'],
            'sourceUrl': upstream['sourceUrl'],
            'downloadUrl': (f'https://github.com/gomeen/gogaku-dicts/releases/'
                            f'download/{tag}/{target.name}'),
            'size': target.stat().st_size,
            'sha256': sha256_of(target),
            'entryCount': count,
        })
        print(f'✔ {upstream["id"]}：{count} 条（丢弃 {sum(report["dropped"].values())}）')

    if args.verify_only:
        return
    if not entries:
        fail('所有词库均为空，无法生成可安装清单')

    catalog = {
        'kind': 'gogaku-dictionary-catalog',
        'schemaVersion': 1,
        'keyId': args.key_id,
        'catalogVersion': args.catalog_version,
        'dictionaries': entries,
    }
    manifest = out / 'catalog.json'
    manifest.write_text(json.dumps(catalog, ensure_ascii=False, separators=(',', ':')),
                        encoding='utf-8')
    signature = out / 'catalog.json.sig'
    signature.unlink(missing_ok=True)
    if not args.unsigned:
        sign(Path(args.key).expanduser(), args.key_id, manifest, signature)

    # 发布记录：每本的丢弃计数（合同要求随 Release 正文发布）。
    notes = out / 'release-notes.md'
    lines = [f'# gogaku-dicts {tag}', '',
             f'本轮转换 {len(conversions)} 个来源，上架 {len(entries)} 本非空词库。', '',
             '| 词库 | 修订 | 上游版本 | 条目 | 状态 | 许可与署名 | 丢弃（invalidLine/middleDot/tooLong/duplicateFactory/duplicateEntry/nonHan/ambiguousReading） |',
             '| --- | --- | --- | --- | --- | --- | --- |']
    for upstream, report in conversions:
        dropped = report['dropped']
        counts = '/'.join(str(dropped.get(key, 0)) for key in
                          ('invalidLine', 'middleDot', 'tooLong', 'duplicateFactory',
                           'duplicateEntry', 'nonHan', 'ambiguousReading'))
        count = report['entryCount']
        status = '上架' if count else '空库，不上架'
        lines.append(f'| {upstream["name"]}（{upstream["id"]}） | {upstream["revision"]} | '
                     f'`{upstream["upstreamRevision"]}` | {count} | {status} | '
                     f'{upstream["license"]}：{upstream["attribution"]} | {counts} |')
    lines += ['',
              'zhwiki 与网络流行语源自维基百科贡献者与 [fcitx5-pinyin-zhwiki](https://github.com/felixonmars/fcitx5-pinyin-zhwiki)。Gogaku 过滤并去重，全部权重归零，转换产物以 CC BY-SA 4.0 共享。', '',
              '韩世依、张钰晖、马云山、涂存超、郭志芃、刘知远、孙茂松。THUOCL：清华大学开放中文词库。2016。THUOCL 词库以 MIT 许可分发。', '',
              '完整许可随 Release 附件提供。']
    notes.write_text('\n'.join(lines) + '\n', encoding='utf-8')
    shutil.copyfile(ROOT / 'resources/dictionaries/THUOCL-LICENSE.txt', out / 'THUOCL-LICENSE.txt')
    shutil.copyfile(ROOT / 'resources/licenses/CC-BY-SA-4.0.txt', out / 'CC-BY-SA-4.0.txt')

    print(f'✔ catalog.json 与 {len(entries)} 本词库已生成于 {out}')
    print('下一步：python3 scripts/publish-dictionaries.py --dry-run')


if __name__ == '__main__':
    main()
