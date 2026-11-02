#!/usr/bin/env python3
"""Gogaku 统一验证入口：三种明确的检查档位，产出机器可读报告。

用法：
  python3 scripts/verify.py --profile fast      # 日常提交：核心＋Release Swift＋版本＋资源
  python3 scripts/verify.py --profile release   # 交付门槛：干净构建＋包检查＋质量＋渲染＋
                                                #            数据可靠性＋ASan/UBSan＋安装预检
  python3 scripts/verify.py --profile host --yes # 真实宿主／性能／稳定性（显式要求，逐项
                                                # 核对前台身份并恢复输入源与焦点）

规则：
- 每项检查输出 passed／failed／skipped／blocked；必需项只有全部 passed 才算
  通过发布门槛（退出码 0）。必需数据缺失、测试跳过、报告缺失都算未完成，
  不会因命令退出 0 而被误读为覆盖完整。
- 报告写入 docs/validation/verify/report-<profile>-<时间戳>.json，含每项状态、
  耗时与证据路径；历史报告不自动继承为当前版本通过（每次重跑重建身份绑定）。
- release 档位不做真实输入注入、不接管桌面；host 档位必须显式 --yes。
"""
import argparse
import json
import os
import platform
import re
import shutil
import subprocess
import sys
import tempfile
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / 'scripts'))
EVIDENCE_DIR = ROOT / 'docs' / 'validation' / 'verify'
CACHE = Path(os.environ.get('GOGAKU_DEPS', Path.home() / 'Library/Caches/Gogaku/libime-1.1.17'))
VERSION_FILE = ROOT / 'version.json'
PASS, FAIL, SKIP, BLOCK = 'passed', 'failed', 'skipped', 'blocked'


def sh(args, timeout=None, env=None, cwd=ROOT, capture=True):
    merged = dict(os.environ)
    merged.setdefault('DEVELOPER_DIR', '/Applications/Xcode.app/Contents/Developer') \
        if Path('/Applications/Xcode.app/Contents/Developer').is_dir() else None
    if env:
        merged.update(env)
    return subprocess.run([str(a) for a in args], cwd=cwd, env=merged, text=True,
                          capture_output=capture, timeout=timeout)


# ── 检查实现 ──────────────────────────────────────────────────────────────

def check_version(ctx):
    """版本来源校验＋拒绝路径自测（非法版本／构建号倒退／dirty 候选）。"""
    import importlib.util
    spec = importlib.util.spec_from_file_location('gogaku_build', ROOT / 'scripts' / 'build.py')
    build = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(build)
    meta = build.load_version()
    problems, rejected = [], 0
    with tempfile.TemporaryDirectory() as tmp:
        def rejects(content, why):
            nonlocal rejected
            p = Path(tmp) / 'version.json'
            p.write_text(content)
            try:
                build.load_version(p)
                problems.append(f'未拒绝：{why}')
            except SystemExit:
                rejected += 1
        rejects('{"version": "01.2.3", "buildNumber": 2}', '非法版本 01.2.3')
        rejects('{"version": "0.1.0-beta.1", "buildNumber": 2}', '非法预发布段 beta.1')
        rejects('{"version": "0.1", "buildNumber": 2}', '两段版本')
        rejects('{"version": "0.1.0", "buildNumber": -1}', '负构建号')
        rejects('{"version": "0.1.0", "buildNumber": "3"}', '字符串构建号')
        rejects('{"version": "0.1.0"}', '缺少构建号')
        rejects('not json', '非法 JSON')
    try:
        build.check_build_number_not_regressing(1, 2)
        problems.append('未拒绝：构建号倒退')
    except SystemExit:
        pass
    try:
        build.require_clean_allowed('rc', True)
        problems.append('未拒绝：dirty 候选构建')
    except SystemExit:
        pass
    # 两套已安装应用版本一致性（存在时）。
    consistency = []
    import plistlib
    apps = [Path.home() / 'Library/Input Methods/Gogaku.app',
            Path.home() / 'Applications/Gogaku Settings.app']
    found = []
    for app in apps:
        plist = app / 'Contents/Info.plist'
        if plist.exists():
            info = plistlib.loads(plist.read_bytes())
            found.append((app.name, info.get('CFBundleShortVersionString'), info.get('CFBundleVersion')))
    if len(found) >= 2:
        versions = {(v, b) for _, v, b in found}
        if len(versions) != 1:
            problems.append(f'两套应用版本不一致：{found}')
        else:
            consistency.append('installed=' + ';'.join(f'{n} {v} b{b}' for n, v, b in found))
    detail = f"version.json={meta['version']} 构建{meta['buildNumber']}；拒绝路径 {rejected}/7；" + '；'.join(consistency)
    if problems:
        return FAIL, detail + '；' + '；'.join(problems), None
    return PASS, detail, None


def check_resources(ctx):
    """随包数据与依赖身份一致性：哈希不符即失败，缺失按缺失记 blocked。"""
    import hashlib
    problems, notes = [], []
    pairs = [('resources/gloss.tsv', 'resources/gloss-sources.json'),
             ('resources/english-words.txt', 'resources/english-wordlist-sources.json')]
    for data_name, manifest_name in pairs:
        data, manifest = ROOT / data_name, ROOT / manifest_name
        if not data.exists() or not manifest.exists():
            notes.append(f'{data_name} 未生成（打包降级，但当前树声明存在清单）'
                         if manifest.exists() else f'{data_name} 与清单均未生成')
            continue
        expected = json.loads(manifest.read_text())['output_sha256']
        digest = hashlib.file_digest(data.open('rb'), 'sha256').hexdigest()
        if digest != expected:
            problems.append(f'{data_name} 哈希与清单不符（{digest[:12]}… ≠ {expected[:12]}…）')
        else:
            notes.append(f'{data_name} 哈希一致')
    lock = CACHE / 'dependencies.lock.json'
    if not lock.exists():
        return BLOCK, '缺少依赖锁 ' + str(lock) + '；先运行 scripts/prepare-dependencies.py', None
    lock_data = json.loads(lock.read_text())
    for name, expected in lock_data['artifacts'].items():
        source = CACHE / 'data' / name
        if not source.exists():
            problems.append(f'依赖数据缺失：{name}')
            continue
        digest = hashlib.file_digest(source.open('rb'), 'sha256').hexdigest()
        if digest != expected:
            problems.append(f'依赖数据哈希不符：{name}')
    if problems:
        return FAIL, '；'.join(problems), None
    return PASS, '；'.join(notes) + f'；依赖锁 {len(lock_data["artifacts"])} 项一致', None


def check_core_tests(ctx):
    """共享核心：Release 构建＋ctest 全量（含 ABI、事件轨迹、质量、fuzz 冒烟）。"""
    result = sh(['cmake', '-S', 'native/GogakuCore', '-B', ctx['core_dir'],
                 '-G', 'Ninja', '-DCMAKE_BUILD_TYPE=Release', f'-DGOGAKU_DEPS={CACHE}'])
    if result.returncode != 0:
        return FAIL, 'cmake 配置失败：' + result.stderr[-400:], None
    result = sh(['cmake', '--build', ctx['core_dir'], '-j', str(ctx['jobs'])])
    if result.returncode != 0:
        return FAIL, '核心构建失败：' + (result.stdout[-300:] + result.stderr[-300:]), None
    env = {'GOGAKU_CORE_TEST_DATA': str(CACHE / 'data')} if (CACHE / 'data').exists() else {}
    result = sh(['ctest', '--test-dir', ctx['core_dir'], '--output-on-failure'], env=env, timeout=1200)
    evidence = ctx.evidence('core-ctest.log', result.stdout + result.stderr)
    if 'SKIP:' in result.stdout:
        return BLOCK, '核心测试输出包含 SKIP（必需数据缺失按未完成计）', evidence
    passed = re.search(r'(\d+)% tests passed', result.stdout)
    if result.returncode != 0 or not passed or passed.group(1) != '100':
        return FAIL, f'ctest 未全过（exit={result.returncode}）', evidence
    return PASS, f'ctest 全过（{passed.group(0)}）', evidence


def check_swift_tests(ctx):
    """Swift 回归：Release 配置（与交付构建一致；Debug 结果不作为通过证据）。"""
    result = sh(['swift', 'test', '-c', 'release', '-j', str(ctx['jobs'])], timeout=1800)
    evidence = ctx.evidence('swift-tests.log', result.stdout + result.stderr)
    executed = re.findall(r'Executed (\d+) tests?, with (\d+) failures?', result.stdout)
    if result.returncode != 0 or not executed:
        return FAIL, f'swift test 未完成（exit={result.returncode}）', evidence
    # XCTest 先逐套件输出 Executed，最后一行是总汇总（含全部套件）；取总行。
    total, failures = int(executed[-1][0]), int(executed[-1][1])
    if total == 0:
        return BLOCK, '未执行任何测试（0 tests）', evidence
    if failures:
        return FAIL, f'{failures}/{total} 失败', evidence
    return PASS, f'{total} 项全部通过（Release）', evidence


def check_clean_build(ctx):
    """干净构建：全新构建根（native/core/swift 互不 reuse）组装安装包，产物身份
    与当前提交绑定。依赖缓存只读复用（不清除用户缓存）。"""
    build_root = ROOT / '.build/verify-clean'
    if build_root.exists():
        shutil.rmtree(build_root)
    result = sh(['python3', 'scripts/build.py', '--configuration', 'release'],
                env={'GOGAKU_BUILD_ROOT': str(build_root)}, timeout=3600)
    evidence = ctx.evidence('clean-build.log', result.stdout + result.stderr)
    if result.returncode != 0:
        return FAIL, '构建失败：' + result.stdout.strip().splitlines()[-1][:200], evidence
    identity = ROOT / 'dist/build-identity.json'
    if not identity.exists():
        return FAIL, '构建未产出 dist/build-identity.json', evidence
    data = json.loads(identity.read_text())
    head = sh(['git', 'rev-parse', 'HEAD']).stdout.strip()
    dirty = bool(sh(['git', 'status', '--porcelain', '--untracked-files=no']).stdout.strip())
    if data['commit'] != head:
        # 允许 HEAD 是身份提交的纯文档后代（验证期间改文档不产生新二进制）；
        # 任何源码/脚本/资源差异仍视为「报告指向旧产物」。
        ancestor = sh(['git', 'merge-base', '--is-ancestor', data['commit'], head]).returncode == 0
        changed = sh(['git', 'diff', '--name-only', data['commit'], head]).stdout.split()
        docs_only = bool(changed) and all(
            c.startswith('docs/') or c in ('README.md', 'CHANGELOG.md', 'AGENTS.md') for c in changed)
        if not (ancestor and docs_only):
            return FAIL, f"身份提交 {data['commit'][:12]} ≠ 当前 HEAD {head[:12]}（报告指向旧产物；变更：{changed[:5]}）", evidence
    if data['dirty']:
        return BLOCK, '构建身份标记 dirty；发布门槛要求源码已提交且工作区干净', evidence
    return PASS, (f"{data['fullVersion']} 构建{data['buildNumber']} 提交 {head[:12]}"
                  f"（两套应用各 {len(data['apps']['Gogaku.app']['files'])}／"
                  f"{len(data['apps']['Gogaku Settings.app']['files'])} 个运行时文件已哈希）"), evidence


def check_bundle(ctx):
    """安装包检查：签名、依赖闭包、包内核心与 helper 冒烟。"""
    if not (ROOT / 'dist/Gogaku.app').exists():
        return BLOCK, '缺少 dist/Gogaku.app；先构建再检查', None
    report_path = ctx.evidence_path('bundle-check.json')
    result = sh(['python3', 'scripts/check-bundle.py',
                 '--report', report_path], timeout=600)
    evidence = report_path.read_text() if Path(report_path).exists() else (result.stdout + result.stderr)
    evidence = ctx.evidence('bundle-check.log', evidence)
    if result.returncode != 0:
        return FAIL, f'包检查失败（exit={result.returncode}）', evidence
    return PASS, '签名、闭包与包内冒烟通过（含输入法与设置应用）', evidence


def check_quality(ctx):
    """冻结中文质量回归：首选≥109／120、前十≥112／120；释义精简不改变排序。"""
    binary = Path(ctx['core_dir']) / 'gogaku_core_quality_test'
    if not binary.exists():
        return BLOCK, '质量测试二进制缺失（核心未构建？）', None
    env = {'GOGAKU_CORE_TEST_DATA': str(CACHE / 'data')} if (CACHE / 'data').exists() else {}
    result = sh([binary], env=env, timeout=600)
    evidence = ctx.evidence('quality.log', result.stdout + result.stderr)
    if 'SKIP:' in result.stderr or 'SKIP:' in result.stdout:
        return BLOCK, '质量测试跳过（缺出厂数据）', evidence
    baseline = re.search(r'首选 (\d+)／120，前十 (\d+)／120', result.stdout + result.stderr)
    if result.returncode != 0 or not baseline:
        return FAIL, '质量回归失败或无基线输出', evidence
    first, top10 = int(baseline.group(1)), int(baseline.group(2))
    if first < 109 or top10 < 112:
        return FAIL, f'质量下降：首选 {first}/120、前十 {top10}/120（门槛 109／112）', evidence
    return PASS, f'首选 {first}/120、前十 {top10}/120（≥109／112）', evidence


def check_render(ctx):
    """候选窗离线渲染回归（AppKit 2x 位图逐项核对）。"""
    triple = 'x86_64-apple-macosx'
    modules = ROOT / f'.build/{triple}/release/Modules'
    objects_dir = ROOT / f'.build/{triple}/release/GogakuCore.build'
    if not modules.exists() or not objects_dir.exists():
        return BLOCK, '缺少 Swift Release 构建产物（先运行 swift build -c release）', None
    binary = ROOT / '.build/render-panel-verify'
    objects = sorted(str(p) for p in objects_dir.rglob('*.o'))
    if not objects:
        return BLOCK, 'GogakuCore 目标文件缺失', None
    compile_cmd = ['swiftc', 'probes/render-candidate-panel.swift',
                   'Sources/GogakuInput/CandidatePanel.swift',
                   'Sources/GogakuInput/CandidatePanelTheme.swift',
                   '-I', str(modules),
                   '-I', 'Sources/CGogakuCore', '-I', 'Sources/CGogakuEngine', '-I', 'Sources/CSQLite',
                   '-L', str(ctx['core_dir']), '-lgogaku_core',
                   '-L', str(ROOT / '.build/native'), '-lGogakuEngine', '-lsqlite3',
                   '-Xlinker', '-rpath', '-Xlinker', str(ctx['core_dir']),
                   '-Xlinker', '-rpath', '-Xlinker', str(ROOT / '.build/native'),
                   *objects, '-o', binary]
    result = sh(compile_cmd, timeout=600)
    if result.returncode != 0:
        return FAIL, '渲染工具编译失败：' + result.stderr[-300:], None
    result = sh([binary], timeout=600, capture=True)
    evidence = ctx.evidence('panel-render.log', result.stdout + result.stderr)
    if result.returncode != 0:
        return FAIL, f'渲染检查失败（exit={result.returncode}）', evidence
    checks = re.findall(r'(\d+) 项', result.stdout)
    return PASS, '渲染检查通过' + (f'（{checks[0]} 项）' if checks else ''), evidence


def check_data_reliability(ctx):
    """数据可靠性 40 轮：强杀、损坏恢复、删除不复活。"""
    worker = Path(ctx['core_dir']) / 'gogaku_data_reliability_worker'
    if not worker.exists():
        return BLOCK, '可靠性 worker 缺失（核心未构建？）', None
    result = sh(['python3', 'probes/validate-data-reliability.py', '--rounds', '40'], timeout=1800)
    evidence = ctx.evidence('data-reliability.log', result.stdout + result.stderr)
    if result.returncode != 0:
        return FAIL, f'数据可靠性失败（exit={result.returncode}）', evidence
    return PASS, '40 轮强杀／损坏恢复／删词不复活通过', evidence


def check_asan_ubsan(ctx):
    """十万随机序列 ASan＋UBSan 插桩回归；中断或未完成计数不算通过。"""
    asan_dir = ROOT / '.build/core-asan'
    result = sh(['cmake', '-S', 'native/GogakuCore', '-B', asan_dir, '-G', 'Ninja',
                 '-DCMAKE_BUILD_TYPE=Debug',
                 '-DCMAKE_C_FLAGS=-fsanitize=address,undefined -fno-omit-frame-pointer',
                 '-DCMAKE_CXX_FLAGS=-fsanitize=address,undefined -fno-omit-frame-pointer',
                 '-DCMAKE_EXE_LINKER_FLAGS=-fsanitize=address,undefined',
                 f'-DGOGAKU_DEPS={CACHE}'])
    if result.returncode != 0:
        return FAIL, 'ASan 配置失败：' + result.stderr[-300:], None
    result = sh(['cmake', '--build', asan_dir, '-j', str(ctx['jobs']), '--target', 'gogaku_core_fuzz'],
                timeout=1800)
    if result.returncode != 0:
        return FAIL, 'ASan 构建失败', None
    binary = asan_dir / 'gogaku_core_fuzz'
    env = {'GOGAKU_CORE_TEST_DATA': str(CACHE / 'data'),
           # macOS 的 ASan 不支持 detect_leaks；强行开启会 SIGABRT。
           'ASAN_OPTIONS': 'detect_leaks=0',
           'UBSAN_OPTIONS': 'print_stacktrace=1:halt_on_error=1'}
    sequences = 2000 if ctx['quick'] else 100000
    result = sh([binary, '20261031', str(sequences)], env=env,
                timeout=600 if ctx['quick'] else 14400)
    # fuzz 全部输出走 stderr（fprintf）；完成判定必须看合并输出。
    combined = (result.stdout or '') + (result.stderr or '')
    evidence = ctx.evidence('asan-ubsan.log', combined[-8000:])
    if result.returncode != 0:
        return FAIL, f'插桩运行失败（exit={result.returncode}；中断或报错均不算通过）', evidence
    if f'{sequences} 序列' not in combined or '— PASS' not in combined:
        return FAIL, '无完成计数输出；不视为通过', evidence
    return PASS, f'{sequences} 随机序列 ASan＋UBSan 无错误' + \
        ('（quick 冒烟，不满足十万门槛）' if ctx['quick'] else ''), evidence


def check_install_preflight(ctx):
    """安装恢复预检：dist 双包签名、双包版本一致、备份不再以可启动 .app 暴露。
    真实安装/恢复由 scripts/manage-install.py install／recover 在用户授权下执行
    （安装后自动核对运行时哈希），不在本档位隐式接管。"""
    import plistlib
    problems = []
    apps = [ROOT / 'dist/Gogaku.app', ROOT / 'dist/Gogaku Settings.app']
    versions = set()
    for app in apps:
        if not app.exists():
            return BLOCK, '缺少 ' + app.name + '；先构建', None
        result = sh(['codesign', '--verify', '--deep', '--strict', app])
        if result.returncode != 0:
            problems.append(app.name + ' 签名校验失败')
        info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
        versions.add((info.get('CFBundleShortVersionString'), info.get('CFBundleVersion')))
        identity = app / 'Contents/Resources/build-identity.json'
        if not identity.exists():
            problems.append(app.name + ' 缺少包内 build-identity.json')
    if len(versions) != 1:
        problems.append(f'两套应用版本不一致：{sorted(versions)}')
    backups = Path.home() / 'Library/Application Support/Gogaku/DeveloperBackups'
    if backups.exists():
        exposed = [str(p) for p in backups.rglob('*.app')]
        if exposed:
            problems.append(f'备份目录仍有可被 LaunchServices 索引的 .app：{exposed[:3]}；'
                            '运行一次 python3 scripts/manage-install.py install（或手动改名 .disabled）清理')
    if problems:
        return FAIL, '；'.join(problems), None
    return PASS, '双包签名／包内身份／双包版本一致；备份无 .app 暴露', None


def check_host_plan(ctx):
    """host 档位预检＋运行计划：真实注入必须显式 --yes，且不与其他检查并行。"""
    installed = (Path.home() / 'Library/Input Methods/Gogaku.app').exists()
    if not installed:
        return BLOCK, '输入法未安装（~/Library/Input Methods/Gogaku.app 不存在）', None
    plan = [
        ('宿主矩阵', 'python3 probes/validate-real-hosts.py --hosts appkit,chrome,safari,terminal,orca '
                     '--iterations 200（每种确认方式 × 后键 × 200 次，连续两轮）'),
        ('Orca Shift 专项', 'python3 probes/first_key_regression.py --hosts orca --iterations 200 '
                            '--enable-validation --report docs/validation/verify/orca-shift.json '
                            '（单独追踪：输入法实际收到的按下／释放事件、组合变化、插字次数、PTY 字节；'
                            '不预设与 Terminal 同因）'),
        ('性能', 'python3 probes/measure-imk-latency.py --events 10000（约万次真实事件，含首次显示；'
                 '计时期间不并行构建）'),
        ('稳定性', '两小时浸泡与内存趋势：宿主矩阵持续运行记录（专用文档／字段／PTY，逐次核对前台身份，'
                   '结束恢复输入源与焦点）'),
    ]
    if not ctx['yes']:
        lines = '\n'.join(f'  - {name}：{cmd}' for name, cmd in plan)
        return BLOCK, ('host 档位需要 --yes 显式确认（将向系统注入真实按键并占用桌面）。'
                       '确认后逐项执行：\n' + lines), None
    failures = []
    for name, cmd in plan:
        result = sh(['bash', '-c', cmd], timeout=14400)
        evidence = ctx.evidence(f'host-{name}.log', result.stdout + result.stderr)
        if result.returncode != 0:
            failures.append(f'{name} 失败（exit={result.returncode}，见 {Path(evidence).name}）')
    if failures:
        return FAIL, '；'.join(failures), ctx.evidence_path('host-summary.txt')
    return PASS, '宿主矩阵／性能／稳定性完成', None


# ── 档位定义 ──────────────────────────────────────────────────────────────

PROFILES = {
    'fast': [
        ('version', True, check_version),
        ('resources', True, check_resources),
        ('core-tests', True, check_core_tests),
        ('swift-tests', True, check_swift_tests),
    ],
    'release': [
        ('version', True, check_version),
        ('resources', True, check_resources),
        ('core-tests', True, check_core_tests),
        ('swift-tests', True, check_swift_tests),
        ('clean-build', True, check_clean_build),
        ('bundle-check', True, check_bundle),
        ('quality', True, check_quality),
        ('render', True, check_render),
        ('data-reliability', True, check_data_reliability),
        ('asan-ubsan', True, check_asan_ubsan),
        ('install-preflight', False, check_install_preflight),
    ],
    'host': [
        ('host-plan', True, check_host_plan),
    ],
}


class Ctx:
    def __init__(self, args):
        self['core_dir'] = ROOT / '.build/core'
        self['jobs'] = args.jobs
        self['quick'] = args.quick
        self['yes'] = args.yes
        self._dir = EVIDENCE_DIR / f'{args.profile}-{time.strftime("%Y%m%d-%H%M%S")}'
        self._dir.mkdir(parents=True, exist_ok=True)

    def __setitem__(self, k, v):
        setattr(self, k, v)

    def __getitem__(self, k):
        return getattr(self, k)

    def evidence_path(self, name):
        return self._dir / name

    def evidence(self, name, text):
        path = self._dir / name
        path.write_text(text or '')
        return str(path)


def main():
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--profile', choices=sorted(PROFILES), required=True)
    parser.add_argument('--jobs', type=int, default=2)
    parser.add_argument('--quick', action='store_true',
                        help='ASan/UBSan 用 2000 序列冒烟（不满足十万序列门槛，仅开发用）')
    parser.add_argument('--yes', action='store_true',
                        help='host 档位：显式确认注入真实按键（不确认则只输出计划并记 blocked）')
    parser.add_argument('--only', default='', help='只运行指定检查（逗号分隔），其余记 skipped')
    parser.add_argument('--report', default='')
    args = parser.parse_args()

    ctx = Ctx(args)
    only = {name.strip() for name in args.only.split(',') if name.strip()}
    started = time.strftime('%Y-%m-%dT%H:%M:%S%z')
    results = []
    for name, required, runner in PROFILES[args.profile]:
        if only and name not in only:
            results.append({'name': name, 'required': required, 'status': SKIP,
                            'detail': '未选中（--only）', 'durationMs': 0, 'evidence': None})
            continue
        t0 = time.monotonic()
        try:
            status, detail, evidence = runner(ctx)
        except Exception as e:  # 检查自身崩溃按失败计，不静默
            status, detail, evidence = FAIL, f'检查异常：{type(e).__name__}: {e}', None
        duration = int((time.monotonic() - t0) * 1000)
        results.append({'name': name, 'required': required, 'status': status,
                        'detail': detail, 'durationMs': duration, 'evidence': evidence})
        print(f"[{status.upper():7s}] {name}（{duration}ms）：{detail}")

    summary = {s: sum(1 for r in results if r['status'] == s) for s in (PASS, FAIL, SKIP, BLOCK)}
    required_bad = [r for r in results if r['required'] and r['status'] != PASS]
    gate = not required_bad
    head = sh(['git', 'rev-parse', 'HEAD']).stdout.strip() or 'no-git'
    dirty = bool(sh(['git', 'status', '--porcelain', '--untracked-files=no']).stdout.strip())
    report = {
        'profile': args.profile, 'startedAt': started,
        'finishedAt': time.strftime('%Y-%m-%dT%H:%M:%S%z'),
        'commit': head, 'dirty': dirty, 'arch': platform.machine(),
        'version': json.loads(VERSION_FILE.read_text()) if VERSION_FILE.exists() else None,
        'checks': results, 'summary': summary,
        'gate': {'passed': gate, 'notPassed': [r['name'] for r in required_bad]},
    }
    out = Path(args.report) if args.report else EVIDENCE_DIR / f'report-{args.profile}-{time.strftime("%Y%m%d-%H%M%S")}.json'
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps(report, ensure_ascii=False, indent=2) + '\n')
    print(f"\n摘要：passed={summary[PASS]} failed={summary[FAIL]} skipped={summary[SKIP]} "
          f"blocked={summary[BLOCK]}；发布门槛：{'通过' if gate else '未通过（' + '、'.join(r['name'] for r in required_bad) + '）'}")
    print(f"报告：{out}")
    return 0 if gate else 1


if __name__ == '__main__':
    sys.exit(main())
