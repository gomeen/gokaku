#!/usr/bin/env python3
"""隔离准备 Rime 中文输入 worker；仅功能冒烟，不运行性能实验。

python3 probes/prepare-rime-input.py [--configs R0 R1 R2]
所有第三方材料、许可、构建日志、用户目录和 manifest 均写入固定 /tmp 目录。
运行阶段只执行 manifest.configs[].command，不会再次部署或下载。
"""
import argparse
import concurrent.futures
import hashlib
import io
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tarfile
import time
import urllib.request

ROOT = Path('/tmp/gogaku-ime-benchmark/rime')
BUNDLE = Path('/Library/Input Methods/Squirrel.app/Contents')
LIB = BUNDLE / 'Frameworks/librime.1.dylib'
PLUGINS = [BUNDLE / 'Frameworks/rime-plugins' / f'librime-{p}.dylib' for p in ('lua', 'octagram')]
PROBES = Path(__file__).resolve().parent
REPOS = {
    'flypy': ('rime/rime-double-pinyin', '01a13287cbd27819be1c34fa1ddc1b3643d5001b', 'GPL-3.0'),
    'ice': ('iDvel/rime-ice', 'da1fbe602e38f26db846fa10120ee64c2b0324c0', 'GPL-3.0-only'),
    'wanxiang': ('amzxyz/rime-wanxiang', '53f839595e38405c295f51e102e6a9662278c1f7', 'CC-BY-4.0'),
    'luna': ('rime/rime-luna-pinyin', '56b934b099dfbeab842320f13aa8b461a6ab3e42', 'LGPL-3.0'),
    'prelude': ('rime/rime-prelude', '082425ea0684bca36474415d4a0e8db9b016487e', 'LGPL-3.0'),
    'essay': ('rime/rime-essay', '054920de4f54c9e5994276a96a4fc2a35cb51aa3', 'LGPL-3.0'),
    'stroke': ('rime/rime-stroke', '1e8fff9b9494ddec23b0cbc526bcfd8171a6fd48', 'LGPL-3.0'),
    'headers': ('rime/librime', '1.16.0', 'BSD-3-Clause'),
    'wanxiang-data': ('amzxyz/rime-wanxiang-data', '6ea60e43339de4257bf815529e0fccac0704670a', 'CC-BY-4.0 (original data only)'),
}
GRAM_SHA = 'e34500ab44626dc039a0641792ecba98ab63307646eb3d29186be56608ffe094'
GRAM_NAME = 'wanxiang-lts-zh-hans.gram'
GRAM_URL = 'https://github.com/amzxyz/rime-wanxiang-data/releases/download/LTS/' + GRAM_NAME


def log(s):
    print(s, file=sys.stderr, flush=True)


def digest(path):
    h = hashlib.sha256()
    with path.open('rb') as f:
        for b in iter(lambda: f.read(1024 * 1024), b''):
            h.update(b)
    return h.hexdigest()


def save_json(path, obj):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(obj, ensure_ascii=False, indent=2) + '\n')


def fetch(url, path):
    path.parent.mkdir(parents=True, exist_ok=True)
    if not path.exists():
        log('下载 ' + url)
        tmp = path.with_name(path.name + '.download')
        for attempt in range(3):
            try:
                with urllib.request.urlopen(urllib.request.Request(url, headers={'User-Agent': 'gogaku-isolated-benchmark'}), timeout=60) as r, tmp.open('wb') as f:
                    shutil.copyfileobj(r, f)
                tmp.replace(path)
                break
            except (OSError, TimeoutError):
                if attempt == 2:
                    raise
                time.sleep(1)
    return path.read_bytes()


def review(name):
    """在取得任何词库/模型包前，取得固定版本许可、包目录、声明与具体数据文件头。"""
    repo, ref, license_id = REPOS[name]
    directory = ROOT / 'licenses' / name
    raw = f'https://raw.githubusercontent.com/{repo}/{ref}/'
    material = []
    paths = ['LICENSE', 'README.md']
    if name == 'ice':
        paths += ['others/docs/Credits.md']
    if name == 'wanxiang-data':
        paths += ['LICENSE-SCOPE.md', 'NOTICE.md']
    for p in paths:
        dest = directory / p
        fetch(raw + p, dest)
        material.append({'path': str(dest), 'url': raw + p, 'sha256': digest(dest)})
    text = (directory / 'LICENSE').read_text()
    expected = 'Attribution' if 'CC-BY' in license_id else 'Redistribution' if license_id == 'BSD-3-Clause' else 'GENERAL PUBLIC LICENSE'
    if expected not in text:
        raise RuntimeError('许可内容与预期不符: ' + name)
    tree_file = directory / 'tree.json'
    tree = json.loads(fetch(f'https://api.github.com/repos/{repo}/git/trees/{ref}?recursive=1', tree_file))
    if tree.get('truncated'):
        raise RuntimeError('包目录被截断: ' + name)
    # 保存数据头的独立审阅证据；仅 Range 请求，防止审阅时整份加载大词表。
    data_paths = [x['path'] for x in tree['tree'] if x['type'] == 'blob' and x['path'].endswith('.dict.yaml')
                  and (name != 'wanxiang-data' or x['path'].startswith('dicts/'))]
    if name == 'essay':
        data_paths += ['essay.txt']
    headers = []
    for p in data_paths:
        dest = directory / 'data-headers' / (p.replace('/', '__') + '.txt')
        if not dest.exists():
            dest.parent.mkdir(parents=True, exist_ok=True)
            req = urllib.request.Request(raw + p, headers={'Range': 'bytes=0-4095'})
            with urllib.request.urlopen(req, timeout=60) as r:
                dest.write_bytes(r.read(4096))
        headers.append({'data_path': p, 'review_header': str(dest), 'sha256': digest(dest)})
    return {'name': name, 'repo': repo, 'ref': ref, 'commit': tree['sha'], 'license': license_id,
            'license_materials': material, 'tree_manifest': str(tree_file), 'tree_sha256': digest(tree_file),
            'data_header_review': headers}


def source(name):
    evidence = review(name)
    repo, ref, _ = REPOS[name]
    dest = ROOT / 'source' / name
    archive = ROOT / 'downloads' / (name + '-' + ref + '.tar.gz')
    url = f'https://codeload.github.com/{repo}/tar.gz/{ref}'
    fetch(url, archive)
    # 只展开普通文件，不接受链接/特殊文件，不复制外部源码到项目。
    if not (dest / '.complete').exists():
        dest.mkdir(parents=True, exist_ok=True)
        with tarfile.open(archive) as tar:
            for m in tar.getmembers():
                relative = Path(*Path(m.name).parts[1:])
                if not m.isfile() or not relative.parts or '..' in relative.parts or relative.is_absolute():
                    continue
                out = dest / relative
                out.parent.mkdir(parents=True, exist_ok=True)
                with tar.extractfile(m) as f, out.open('wb') as target:
                    shutil.copyfileobj(f, target)
        (dest / '.complete').write_text(ref)
    evidence.update({'source_dir': str(dest), 'archive_url': url, 'archive_sha256': digest(archive)})
    files = [{'path': str(p.relative_to(dest)), 'sha256': digest(p), 'bytes': p.stat().st_size}
             for p in sorted(dest.rglob('*')) if p.is_file() and p.name != '.complete']
    save_json(ROOT / 'licenses' / name / 'files.json', files)
    evidence['files_manifest'] = str(ROOT / 'licenses' / name / 'files.json')
    # 第三方脚本的单独声明与原始数据头逐项保留，主许可不替代这些声明。
    notices = []
    for p in dest.rglob('*'):
        if p.is_file() and (p.suffix in ('.lua', '.yaml') or p.name == 'Credits.md'):
            with p.open(errors='replace') as f:
                head = ''.join(next(f, '') for _ in range(35))
            if any(s in head.lower() for s in ('license', 'copyright', '许可证', 'http')):
                notices.append({'path': str(p.relative_to(dest)), 'header': head})
    save_json(ROOT / 'licenses' / name / 'third-party-headers.json', notices)
    evidence['third_party_notices'] = str(ROOT / 'licenses' / name / 'third-party-headers.json')
    return dest, evidence


def run(command, logfile, timeout=900):
    logfile.parent.mkdir(parents=True, exist_ok=True)
    with logfile.open('w') as f:
        p = subprocess.run([str(v) for v in command], stdout=f, stderr=subprocess.STDOUT, timeout=timeout)
    if p.returncode:
        raise RuntimeError(f'命令失败 ({p.returncode})；日志 {logfile}')


def build_worker():
    evidence = review('headers')
    directory = ROOT / 'include'
    directory.mkdir(exist_ok=True)
    repo, ref, _ = REPOS['headers']
    header = directory / 'rime_api.h'
    fetch(f'https://raw.githubusercontent.com/{repo}/{ref}/src/rime_api.h', header)
    evidence['header_sha256'] = digest(header)
    prefix = subprocess.check_output(['brew', '--prefix', 'json-c'], text=True).strip()
    binary = ROOT / 'rime-input-worker'
    command = ['clang', '-O2', '-std=c11', '-Wall', '-Wextra', '-Werror', '-I' + str(directory),
               '-I' + prefix + '/include', str(PROBES / 'rime-input-worker.c'),
               '-L' + prefix + '/lib', '-ljson-c', '-o', str(binary)]
    run(command, ROOT / 'logs/build-worker.log', 60)
    inspect_command = [str(binary), '--library', str(LIB)]
    for p in PLUGINS:
        inspect_command += ['--plugin', str(p)]
    inspected = json.loads(subprocess.check_output(inspect_command + ['--inspect'], text=True))
    if inspected['version'] != ref or not inspected['lua'] or not inspected['octagram']:
        raise RuntimeError('实际 librime/插件不满足要求: ' + str(inspected))
    # 已安装运行库不重新分发。源码许可单独保留；未知二进制对应提交明确记为未知。
    return binary, {'inspect': inspected, 'library': str(LIB), 'library_sha256': digest(LIB),
                    'source_commit_of_installed_binary': None,
                    'headers': evidence, 'build_command': command, 'binary_sha256': digest(binary),
                    'worker_source_sha256': digest(PROBES / 'rime-input-worker.c'),
                    'plugins': [{'path': str(p), 'sha256': digest(p), 'source_commit_of_installed_binary': None}
                                for p in PLUGINS],
                    'json_c_prefix': prefix, 'json_c_version': subprocess.check_output(['brew', 'list', '--versions', 'json-c'], text=True).strip()}


def copy_runtime(src, dest):
    """仅复制输入法运行资源；原始快照与其完整许可保留在 source。"""
    for p in src.iterdir():
        if p.is_file() and p.suffix in ('.yaml', '.txt', '.gram'):
            shutil.copy2(p, dest / p.name)
        elif p.is_dir() and p.name in ('lua', 'opencc', 'cn_dicts', 'en_dicts', 'dicts'):
            shutil.copytree(p, dest / p.name, dirs_exist_ok=True)


def patch_file(path, patch):
    path.write_text('patch:\n' + ''.join('  ' + json.dumps(k, ensure_ascii=False) + ': ' + json.dumps(v, ensure_ascii=False) + '\n' for k, v in patch.items()))


def grammar():
    evidence = review('wanxiang-data')
    # 只取数据资产，绝不下载该 data 仓库未授予独立许可的工具代码包。
    release_path = ROOT / 'licenses/wanxiang-data/LTS-release.json'
    release = json.loads(fetch('https://api.github.com/repos/amzxyz/rime-wanxiang-data/releases/tags/LTS', release_path))
    asset = next(a for a in release['assets'] if a['id'] == 676604065 and a['name'] == GRAM_NAME)
    if asset['digest'] != 'sha256:' + GRAM_SHA or asset['size'] != 418078764:
        raise RuntimeError('grammar 发布包内容/哈希与固定资产不符')
    dest = ROOT / GRAM_NAME
    part = ROOT / (GRAM_NAME + '.part')
    if part.exists() and digest(part) == GRAM_SHA:
        part.replace(dest)
    if not dest.exists():
        run(['curl', '--fail', '--location', '--retry', '2', '--continue-at', '-', '--output', str(part), GRAM_URL], ROOT / 'logs/download-grammar.log')
        if digest(part) != GRAM_SHA:
            raise RuntimeError('grammar SHA256 不符')
        part.replace(dest)
    if digest(dest) != GRAM_SHA:
        raise RuntimeError('grammar SHA256 不符')
    evidence['model'] = {'path': str(dest), 'sha256': GRAM_SHA, 'url': GRAM_URL, 'asset_id': asset['id'],
                         'size': dest.stat().st_size, 'license': 'CC-BY-4.0', 'contents': ['single binary grammar; no executable/tool bundle'],
                         'source_commit_of_binary': None,
                         'provenance_limit': 'data 文档固定于指定提交；grammar 是独立固定 SHA256 发布资产，未声称其由该提交生成',
                         'release_metadata': str(release_path)}
    return dest, evidence


def smoke(config):
    path = ROOT / config['id'] / 'smoke.jsonl'
    err = ROOT / 'logs' / (config['id'] + '-smoke.stderr.log')
    records = []
    with err.open('w') as f:
        p = subprocess.Popen(config['command'], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=f, text=True, bufsize=1)
        def read():
            line = p.stdout.readline()
            if not line:
                raise RuntimeError('worker 提前退出，见 ' + str(err))
            obj = json.loads(line); records.append(obj); return obj
        def request(op, **kw):
            p.stdin.write(json.dumps({'op': op, **kw}) + '\n'); p.stdin.flush()
            o = read()
            assert all(k in o for k in ('ok', 'handled', 'preedit', 'raw_input', 'candidates', 'commit', 'composing', 'process_ns', 'collect_ns', 'total_ns'))
            assert len(o['candidates']) <= 10 and o['total_ns'] == o['process_ns'] + o['collect_ns']
            return o
        try:
            ready = read(); assert ready['ready']
            results = {}
            for keys in ('nihc', 'kdhv', 'woxlxtykyu'):
                r = request('reset'); assert not r['commit'] and not r['composing']
                for c in keys:
                    last = request('key', key=ord(c)); assert last['ok']
                peek = request('peek'); assert peek['commit'] == ''
                selection = request('select', index=0)
                assert selection['ok']
                assert request('peek')['commit'] == ''
                results[keys] = {'final': last, 'peek': peek, 'select0': selection}
                request('reset')
                for c in keys:
                    request('key', key=ord(c))
                results[keys]['space'] = request('key', key=32)
            request('reset')
            for c in 'nihc': request('key', key=ord(c))
            assert request('key', key=8)['raw_input'] == 'nih'
            assert request('key', key=27)['raw_input'] == ''
            for c in 'nihc': request('key', key=ord(c))
            assert request('reset')['commit'] == ''
            assert request('peek')['raw_input'] == ''
            assert not request('select', index=9)['ok']
            assert not request('key', key=True)['ok']
            assert not request('bogus')['ok']
            # 部分选词不能被适配器强行 commit 或清除剩余码。
            request('reset')
            for c in 'woxlxtykyu': request('key', key=ord(c))
            partial = request('select', index=9)
            results['prefix_selection_index9'] = partial
            p.stdin.write('{"op":"quit"}\n'); p.stdin.flush(); assert read()['quit']
            p.wait(timeout=30)
            if p.returncode: raise RuntimeError('worker 退出失败')
        finally:
            if p.poll() is None:
                p.kill(); p.wait()
            path.write_text(''.join(json.dumps(o, ensure_ascii=False) + '\n' for o in records))
    errors = err.read_text(errors='replace')
    if re.search(r'Error|failed|not found|unavailable|error loading|not loaded', errors, re.I):
        raise RuntimeError('运行期插件/组件报错，见 ' + str(err))
    save_json(ROOT / config['id'] / 'smoke-summary.json', results)
    return {'transcript': str(path), 'stderr': str(err), 'results': results, 'performance_run': False}


def prepare(cid, binary, sources):
    directory = ROOT / cid
    shared, build, users = [directory / s for s in ('shared', 'build', 'users')]
    for d in (shared, build, users): d.mkdir(parents=True, exist_ok=True)
    needed = {'R0': ['prelude', 'essay', 'luna', 'stroke', 'flypy'], 'R1': ['ice'], 'R2': ['wanxiang']}[cid]
    materials = []
    for n in needed:
        if n not in sources: sources[n] = source(n)
        src, ev = sources[n]; copy_runtime(src, shared); materials.append(ev)
    if cid == 'R2':
        # 固定 data 提交的同名基础词表覆盖方案仓库内附带的词表；不取扩展包/工具源码。
        evidence = review('wanxiang-data')
        repo, ref, _ = REPOS['wanxiang-data']
        data_files = []
        for target in sorted((shared / 'dicts').glob('*.dict.yaml')):
            relative = 'dicts/' + target.name
            original = ROOT / 'source/wanxiang-data' / relative
            url = f'https://raw.githubusercontent.com/{repo}/{ref}/{relative}'
            fetch(url, original)
            shutil.copy2(original, target)
            data_files.append({'path': relative, 'url': url, 'sha256': digest(original)})
        evidence['used_data_files'] = data_files
        materials.append(evidence)
    # 公共 OpenCC 资源只读拷贝到隔离区，无个人 Rime 目录。
    public = BUNDLE / 'SharedSupport/opencc'
    shutil.copytree(public, shared / 'opencc', dirs_exist_ok=True)
    public_evidence = [{'path': str(p), 'sha256': digest(p)} for p in sorted(public.rglob('*')) if p.is_file()]
    materials.append({'name': 'Squirrel public OpenCC', 'path': str(public), 'license': 'Apache-2.0 (OpenCC)', 'files': public_evidence})
    schema = 'wanxiang' if cid == 'R2' else 'double_pinyin_flypy'
    patches = {'menu/page_size': 10, 'translator/enable_user_dict': False,
               'translator/enable_encoder': False, 'translator/encode_commit_history': False,
               'reverse_lookup/enable_user_dict': False}
    options = {'ascii_mode': False, 'full_shape': False, 'ascii_punct': False}
    modifications = ['menu.page_size=10；通过 get_context 一次实际生成并复制前十，避免再次枚举相同页面',
                     '每进程新用户目录链接公共Lua/词表和预部署文件；build内可写数据库独立，不读取私人配置',
                     '质量pass的reset(fresh=true)重新创建session以清除commit_history；计时pass只清composition且不提交',
                     '每进程新建临时用户目录；主翻译器及各辅助翻译器禁用用户词典/历史编码，不调用学习 API',
                     '仅加载本地 default/Lua/octagram，不加载 predict、云或神经重排插件']
    disabled = ['云功能、神经重排、用户学习']
    missing = []
    deploy = {'R0': ['stroke', schema], 'R1': ['melt_eng', 'radical_pinyin', schema],
              'R2': ['wanxiang_english', 'wanxiang_mixedcode', 'wanxiang_reverse', 'wanxiang_abbrev', 'wanxiang_phrase', schema]}[cid]
    if cid == 'R0':
        options['simplification'] = True
        modifications += ['simplification=true；朙月繁体源词典经 OpenCC 转为简体；无 grammar/Lua 方案功能']
    elif cid == 'R1':
        options['traditionalization'] = False
        patches.update({'melt_eng/enable_user_dict': False, 'cn_en/enable_user_dict': False,
                        'radical_lookup/enable_user_dict': False, 'custom_phrase/enable_user_dict': False})
        modifications += ['traditionalization=false；保留上游 Emoji 开关默认、完整 Lua 处理链及中英混输；未加装可选 grammar']
    else:
        gram, evidence = grammar(); materials.append(evidence)
        if not (shared / GRAM_NAME).exists():
            os.link(gram, shared / GRAM_NAME)
        options.update({'s2s': True, 's2t': False, 's2hk': False, 's2tw': False, 'context_reorder': False})
        # 学习模块的 init 会监听 commit 或持久写入；只设置 runtime option 不足以禁学习。
        text = (shared / 'wanxiang.schema.yaml').read_text()
        blocked_modules = ('wanxiang.context_reorder', 'wanxiang.auto_phrase', 'wanxiang.input_statistics', 'wanxiang.super_sequence')
        lines = text.splitlines(True)
        removed = [l.strip().split('#')[0].strip() for l in lines if any(n in l and l.lstrip().startswith('- lua_') for n in blocked_modules)]
        text = ''.join(l for l in lines if not any(n in l and l.lstrip().startswith('- lua_') for n in blocked_modules))
        (shared / 'wanxiang.schema.yaml').write_text(text)
        patches.update({'speller/algebra': {'__patch': ['wanxiang_algebra:/base/小鹤双拼']},
                        'wanxiang_english/enable_user_dict': False, 'wanxiang_mixedcode/enable_user_dict': False,
                        'custom_phrase/enable_user_dict': False, 'abbrev_phrase/enable_user_dict': False,
                        'add_user_dict/enable_auto_phrase': False, 'add_user_dict/enable_user_dict': False})
        modifications += ['speller.algebra 选择上游 base/小鹤双拼；s2s=true、其余繁体开关 false',
                          '保留 grammar 与其余 Lua；禁用监听 commit 的学习/统计/持久手动排序组件: ' + ', '.join(removed)]
        disabled += ['Lua context_reorder、auto_phrase、input_statistics、super_sequence（测试隔离要求；不是完整默认体验）']
    patch_file(shared / (schema + '.custom.yaml'), patches)
    patch_file(shared / 'default.custom.yaml', {'menu/page_size': 10, 'schema_list': [{'schema': schema}], 'switcher/save_options': []})
    # 辅助 schema 的 translator 同样关闭用户学习。
    for dep in deploy:
        if dep != schema:
            patch_file(shared / (dep + '.custom.yaml'), {'translator/enable_user_dict': False,
                                                        'translator/enable_encoder': False,
                                                        'translator/encode_commit_history': False})
    config = {'id': cid, 'schema': schema, 'runtime_options': options, 'candidate_limit': 10,
              'raw_input_source': 'RimeApi.get_input；部分选择后可保留已选部分的原始码，按 API 原样报告',
              'options_modified': modifications, 'disabled_features': disabled, 'missing_plugins_or_features': missing}
    config_path = directory / 'worker-config.json'; save_json(config_path, config)
    command = [str(binary), '--library', str(LIB), '--shared', str(shared), '--build', str(build),
               '--users', str(users), '--schema', schema, '--id', cid, '--config', str(config_path)]
    if cid != 'R0':
        for p in PLUGINS: command += ['--plugin', str(p)]
    deploy_command = command[:]
    for dep in deploy: deploy_command += ['--deploy', dep]
    log('部署 ' + cid)
    run(deploy_command, ROOT / 'logs' / (cid + '-deploy.log'))
    config.update({'command': command, 'materials': materials, 'deploy_command': deploy_command,
                   'patches': patches, 'status': 'deployed', 'included': False,
                   'runtime_files': [{'path': str(p.relative_to(directory)), 'sha256': digest(p)}
                                     for d in (shared, build) for p in sorted(d.rglob('*')) if p.is_file()]})
    config['smoke'] = smoke(config)
    config['status'] = 'ready'; config['included'] = True
    return config


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--configs', nargs='+', choices=['R0', 'R1', 'R2'], default=['R0', 'R1', 'R2'])
    args = parser.parse_args()
    ROOT.mkdir(parents=True, exist_ok=True)
    manifest = {'scope': 'isolated librime product-data configurations; smoke only, no performance measurement',
                'personal_rime_dirs_accessed': False, 'input_source_registered_or_switched': False,
                'configs': [], 'blocked_configs': []}
    binary, engine = build_worker(); manifest['engine'] = engine
    sources = {}
    for cid in args.configs:
        try:
            config = prepare(cid, binary, sources)
            manifest['configs'].append(config)
            log(cid + ' 部署/冒烟通过')
        except Exception as e:
            log(cid + ': ' + str(e))
            manifest['blocked_configs'].append({'id': cid, 'included': False, 'command': [],
                'status': 'blocked', 'reason': str(e), 'logs': str(ROOT / 'logs'),
                'quality_failure': False, 'sources': [v[1] for v in sources.values()]})
        save_json(ROOT / 'manifest.json', manifest)
    print(str(ROOT / 'manifest.json'))


if __name__ == '__main__':
    main()
