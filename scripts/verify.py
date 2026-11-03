#!/usr/bin/env python3
"""Gogaku 统一验证入口：三种明确的检查档位，产出机器可读报告。

验证节奏（开发要快，全量留给里程碑与排查）：
  python3 scripts/verify.py --profile fast       # 平时开发（约 2 分钟）：关键测试——核心
                                                 # ctest＋Release Swift＋版本＋资源
  python3 scripts/verify.py --profile release --only asan-ubsan --quick
                                                 # 核心／内存敏感改动后（约 4 分钟）：
                                                 # ASan/UBSan 2000 序列冒烟（不满足
                                                 # 十万序列门槛，证据须注明）
  python3 scripts/verify.py --profile release    # 发版本／交付 rc／定版／疑难排查（约
                                                 # 2.5 小时，建议后台跑）：干净构建＋包
                                                 # 检查＋质量＋渲染＋数据可靠性＋十万序
                                                 # 列 ASan/UBSan＋安装预检
  python3 scripts/verify.py --profile host --yes # 真实宿主／性能／稳定性（显式要求，逐项
                                                 # 核对前台身份并恢复输入源与焦点；仅在
                                                 # 用户空闲时段执行）

规则：
- 每项检查输出 passed／failed／skipped／blocked；必需项只有全部 passed 才算
  通过发布门槛（退出码 0）。必需数据缺失、测试跳过、报告缺失都算未完成，
  不会因命令退出 0 而被误读为覆盖完整。
- 报告写入 docs/validation/verify/report-<profile>-<时间戳>.json，含每项状态、
  耗时与证据路径；历史报告不自动继承为当前版本通过（每次重跑重建身份绑定）。
- --quick 的 ASan 冒烟允许开发期快速回归，但其报告会注明「不满足十万序列
  门槛」；对外交付（rc／定版）必须以完整十万序列报告为准。
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


def check_translation_eval_regression(ctx):
    """翻译评测管线回归：专项集加载、超预算不报通过、缺失审阅不报完成等断言。"""
    result = sh(['python3', 'scripts/validate-translation-eval.py'], timeout=600)
    evidence = ctx.evidence('translation-eval-regression.log', result.stdout + result.stderr)
    if result.returncode != 0:
        return FAIL, f'评测回归失败（exit={result.returncode}）', evidence
    m = re.search(r'(\d+) 项断言全部通过', result.stdout)
    return PASS, '评测管线回归通过' + (f'（{m.group(1)} 项断言）' if m else ''), evidence


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
    """host 档位预检：安装件存在性与身份说明；真实注入必须显式 --yes。"""
    installed = (Path.home() / 'Library/Input Methods/Gogaku.app').exists()
    settings_app = (Path.home() / 'Applications/Gogaku Settings.app').exists()
    if not installed or not settings_app:
        missing = []
        if not installed:
            missing.append('~/Library/Input Methods/Gogaku.app')
        if not settings_app:
            missing.append('~/Applications/Gogaku Settings.app')
        return BLOCK, '输入法未安装（缺 ' + '、'.join(missing) + '）；先构建并安装', None
    plan = (
        'host 档位需要 --yes 显式确认（将向系统注入真实按键并占用桌面）。确认后逐项执行：\n'
        '  - host-identity：安装件身份与 version.json 一致性核对\n'
        f'  - host-matrix-round-1／round-2：probes/validate-real-hosts.py --hosts {HOST_MATRIX_HOSTS} --iterations 200（连续两轮）\n'
        '  - orca-shift：probes/first_key_regression.py --hosts orca-pty --iterations 200 --enable-validation（逐事件核对按下／释放、组合变化、插字次数、PTY 字节）\n'
        '  - performance：probes/measure-imk-latency.py --events 10000（约万次真实事件；计时期间不并行构建）\n'
        '  - stability：probes/stability-soak.py --minutes 120（两小时浸泡，逐轮报告＋内存趋势）\n'
        '  - native-gui：设置六页 × 两种窗口尺寸 × 浅／深外观的真实点击／键盘导航验收（目前无自动化探针，需人工核对后归档证据）'
    )
    if not ctx['yes']:
        return BLOCK, plan, None
    return PASS, 'host 档位预检通过（安装件存在）', None


HOST_MATRIX_HOSTS = 'textedit,chrome,safari,terminal,orca-pty'


def _installed_identity(ctx):
    """安装件身份：双包存在、版本与 version.json 一致（CFBundleShortVersionString
    只存三段数字，预发布段按 build.py 同一规则剥离）；返回 (detail, problems, sha)。"""
    import plistlib
    import hashlib
    version_data = json.loads(VERSION_FILE.read_text()) if VERSION_FILE.exists() else {}
    expected_release = (version_data.get('version'), str(version_data.get('buildNumber')))
    problems, notes = [], []
    binary = Path.home() / 'Library/Input Methods/Gogaku.app/Contents/MacOS/GogakuInput'
    apps = [Path.home() / 'Library/Input Methods/Gogaku.app',
            Path.home() / 'Applications/Gogaku Settings.app']
    for app in apps:
        plist = app / 'Contents/Info.plist'
        if not plist.exists():
            problems.append(f'{app} 缺少 Info.plist')
            continue
        info = plistlib.loads(plist.read_bytes())
        got = (info.get('CFBundleShortVersionString'), str(info.get('CFBundleVersion')))
        expected = (str(expected_release[0]).split('-', 1)[0], expected_release[1])
        if got != expected:
            problems.append(f'{app.name} 版本 {got} ≠ version.json {expected}')
        else:
            notes.append(f'{app.name} {got[0]} b{got[1]}')
    sha = hashlib.file_digest(binary.open('rb'), 'sha256').hexdigest() if binary.exists() else None
    if sha is None:
        problems.append('输入法主二进制不存在：' + str(binary))
    return '；'.join(notes), problems, sha


def _host_json_problems(report_path, expect_sha, min_checks=1):
    """核对宿主报告：结果文件可读、完成数量达标、失败为 0、安装件身份一致。
    缺证据按 blocked 处理（返回 None 表示需 blocked）。"""
    if not Path(report_path).exists():
        return None
    try:
        report = json.loads(Path(report_path).read_text())
    except json.JSONDecodeError:
        return None
    problems = []
    checks = report.get('checks')
    failures = report.get('failures')
    if not isinstance(checks, list) or failures is None:
        problems.append('报告缺少 checks／failures 字段')
    else:
        if len(checks) < min_checks:
            problems.append(f'检查数 {len(checks)} < 门槛 {min_checks}')
        if failures != 0:
            problems.append(f'失败 {failures} 项')
    sha = report.get('inputSource', {}).get('installedSHA256')
    if expect_sha and sha != expect_sha:
        problems.append(f"报告安装件身份 {str(sha)[:12]} ≠ 当前安装件 {str(expect_sha)[:12]}")
    skipped = report.get('skipped') or []
    if skipped:
        problems.append(f"有 {len(skipped)} 个宿主被跳过：" + '; '.join(s.get('host', '?') for s in skipped[:4]))
    return problems


def check_host_identity(ctx):
    notes, problems, sha = _installed_identity(ctx)
    ctx['installed_sha'] = sha
    if problems:
        return FAIL, '；'.join(problems), None
    return PASS, '安装件身份与 version.json 一致（' + notes + f'；输入法 SHA-256 {sha[:12]}…）', None


def check_host_matrix_round(ctx, round_no):
    if not ctx['yes']:
        return BLOCK, 'host 档位需要 --yes', None
    expect_sha = ctx.get('installed_sha')
    report_path = ctx.evidence_path(f'real-host-matrix-round-{round_no}.json')
    evidence_path = ctx.evidence_path(f'real-host-matrix-round-{round_no}.jsonl')
    result = sh(['python3', 'probes/validate-real-hosts.py',
                 '--hosts', HOST_MATRIX_HOSTS, '--iterations', '200',
                 '--report', report_path, '--evidence', evidence_path], timeout=14400)
    log = ctx.evidence(f'host-matrix-round-{round_no}.log', result.stdout + result.stderr)
    problems = _host_json_problems(report_path, expect_sha)
    if problems is None:
        return BLOCK, f'第 {round_no} 轮报告缺失或不可读（exit={result.returncode}，见日志）', log
    if result.returncode == 5:
        return FAIL, f'第 {round_no} 轮前台身份断言失败，整轮中止', log
    if problems:
        return FAIL, f'第 {round_no} 轮未通过：' + '；'.join(problems), log
    report = json.loads(Path(report_path).read_text())
    hosts = report.get('hosts')
    return PASS, ('第 %d 轮通过（%d 项检查；宿主 %s）' % (round_no, len(report['checks']), hosts)), log


def check_orca_shift(ctx):
    if not ctx['yes']:
        return BLOCK, 'host 档位需要 --yes', None
    expect_sha = ctx.get('installed_sha')
    report_path = ctx.evidence_path('orca-shift.json')
    result = sh(['python3', 'probes/first_key_regression.py', '--hosts', 'orca-pty',
                 '--iterations', '200', '--enable-validation', '--report', report_path], timeout=14400)
    log = ctx.evidence('orca-shift.log', result.stdout + result.stderr)
    problems = _host_json_problems(report_path, expect_sha)
    if problems is None:
        return BLOCK, 'Orca Shift 专项报告缺失或不可读', log
    if problems:
        return FAIL, 'Orca Shift 专项未通过：' + '；'.join(problems), log
    report = json.loads(Path(report_path).read_text())
    return PASS, f'Orca Shift 专项通过（{len(report["checks"])} 项检查，含逐事件核对）', log


def check_host_performance(ctx):
    if not ctx['yes']:
        return BLOCK, 'host 档位需要 --yes', None
    report_path = ctx.evidence_path('imk-latency.json')
    samples_path = ctx.evidence_path('imk-latency-samples.json')
    result = sh(['python3', 'probes/measure-imk-latency.py', '--events', '10000',
                 '--report', report_path, '--samples', samples_path,
                 '--evidence', ctx.evidence_path('imk-latency-cycles.jsonl')], timeout=14400)
    log = ctx.evidence('performance.log', result.stdout + result.stderr)
    if not Path(report_path).exists():
        return BLOCK, '性能报告缺失（exit=' + str(result.returncode) + '）', log
    report = json.loads(Path(report_path).read_text())
    acceptance = report.get('acceptance')
    if not isinstance(acceptance, dict) or 'passed' not in acceptance:
        return FAIL, '性能报告缺少 acceptance 判定', log
    events = report.get('events') or report.get('sampleCount')
    detail = '性能门槛判定：' + json.dumps(acceptance.get('checks', acceptance), ensure_ascii=False)[:300]
    if result.returncode != 0 or not acceptance['passed']:
        return FAIL, detail, log
    return PASS, detail, log


def check_host_stability(ctx):
    if not ctx['yes']:
        return BLOCK, 'host 档位需要 --yes', None
    report_path = ctx.evidence_path('stability-soak.json')
    result = sh(['python3', 'probes/stability-soak.py', '--minutes', '120',
                 '--hosts', 'textedit,orca-pty', '--iterations', '25',
                 '--report', report_path], timeout=14400)
    log = ctx.evidence('stability.log', result.stdout + result.stderr)
    if not Path(report_path).exists():
        return BLOCK, '稳定性报告缺失', log
    report = json.loads(Path(report_path).read_text())
    duration_min = (report.get('durationSeconds') or 0) / 60
    trend = report.get('memoryTrend') or []
    problems = []
    if report.get('badRounds'):
        problems.append('异常轮次 ' + str(report['badRounds']))
    if report.get('totalFailures'):
        problems.append('失败 %d 项' % report['totalFailures'])
    if report.get('aborted'):
        problems.append('中止：' + json.dumps(report['aborted'], ensure_ascii=False))
    if duration_min < 110:
        problems.append(f'时长 {duration_min:.1f} 分钟 < 110 分钟门槛')
    if len(trend) < 2:
        problems.append('内存趋势样本不足')
    if problems:
        return FAIL, '稳定性未通过：' + '；'.join(problems), log
    memory = report.get('memorySummaryKB', {})
    return PASS, ('稳定性通过（%.0f 分钟 / %s 轮 / %s 项检查；内存峰值 %sKB，均值 %sKB）'
                  % (duration_min, report.get('roundsCompleted'), report.get('totalChecks'),
                     memory.get('maxRSSKB'), memory.get('meanRSSKB'))), log


def check_native_gui(ctx):
    """原生 GUI 验收：目前无自动化探针。必须有已归档的人工验收证据，缺证据记 blocked。"""
    evidence = ROOT / 'docs/validation/verify' / 'native-gui-acceptance.json'
    if evidence.exists():
        try:
            report = json.loads(evidence.read_text())
            commit = report.get('commit')
            pages = report.get('pages')
            if commit and pages and report.get('pass'):
                return PASS, f"GUI 验收已归档（六页×两尺寸×浅深，提交 {str(commit)[:12]}）", str(evidence)
        except json.JSONDecodeError:
            pass
        return FAIL, 'GUI 验收证据存在但字段不完整（需 commit／pages／pass）', str(evidence)
    return BLOCK, ('原生 GUI 验收未归档：需六页 × 900×620／760×520 × 浅／深的真实点击、'
                   '键盘导航、录制与应用选择验收，读落盘配置并截图；证据写入 '
                   + str(evidence) + '（含 commit、pages、pass 字段）', None)


# ── 档位定义 ──────────────────────────────────────────────────────────────

PROFILES = {
    'fast': [
        ('version', True, check_version),
        ('resources', True, check_resources),
        ('core-tests', True, check_core_tests),
        ('swift-tests', True, check_swift_tests),
        ('translation-eval-regression', True, check_translation_eval_regression),
    ],
    'release': [
        ('version', True, check_version),
        ('resources', True, check_resources),
        ('core-tests', True, check_core_tests),
        ('swift-tests', True, check_swift_tests),
        ('translation-eval-regression', True, check_translation_eval_regression),
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
        ('host-identity', True, check_host_identity),
        ('host-matrix-round-1', True, lambda ctx: check_host_matrix_round(ctx, 1)),
        ('host-matrix-round-2', True, lambda ctx: check_host_matrix_round(ctx, 2)),
        ('orca-shift', True, check_orca_shift),
        ('performance', True, check_host_performance),
        ('stability', True, check_host_stability),
        ('native-gui', True, check_native_gui),
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
