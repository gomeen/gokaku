#!/usr/bin/env python3
"""Gogaku 统一验证入口：三种明确的检查档位，产出机器可读报告。

验证节奏（开发要快，全量留给里程碑与排查）：
  python3 scripts/verify.py --profile fast       # 平时开发（约 2 分钟）：关键测试——核心
                                                 # ctest＋Release Swift＋版本／资源＋数据和门禁负例
  python3 scripts/verify.py --profile release --only asan-ubsan --quick
                                                 # 核心／内存敏感改动后（约 4 分钟）：
                                                 # ASan/UBSan 2000 序列冒烟（不满足
                                                 # 十万序列门槛，证据须注明）
  python3 scripts/verify.py --profile release    # 定版／疑难排查（约 15 分钟，ASan 默认
                                                 # 按核数分片并行）：干净构建＋包检查＋
                                                 # 质量＋渲染＋数据可靠性＋十万序列
                                                 # ASan/UBSan（安装预检可选）
  python3 scripts/verify.py --profile host --yes # 短档真实宿主（每次 stable 定版）：一轮
                                                 # 矩阵＋万次性能＋GUI 抽查（七页×默认
                                                 # 尺寸×浅深）；仅在用户空闲时段执行
  python3 scripts/verify.py --profile host-full --yes
                                                 # 完整宿主：两轮矩阵＋Orca Shift＋性能＋
                                                 # 两小时浸泡＋GUI 全矩阵；核心／IMK
                                                 # 改动或里程碑时执行

规则：
- 每项检查输出 passed／failed／skipped／blocked；必需项只有全部 passed 才算
  通过发布门槛（退出码 0）。必需数据缺失、测试跳过、报告缺失都算未完成，
  不会因命令退出 0 而被误读为覆盖完整。
- 报告写入 docs/validation/verify/report-<profile>-<时间戳>.json，含每项状态、
  耗时与证据路径；历史报告不自动继承为当前版本通过（每次重跑重建身份绑定）。
- --quick 的 ASan 冒烟允许开发期快速回归，但其报告会注明「不满足十万序列
  门槛」；定版必须以完整十万序列报告为准。
- macOS 上运行期间自动用 caffeinate 阻止空闲睡眠（GOGAKU_NO_CAFFEINATE=1 关闭）；
  合盖且无外接显示器时系统仍会睡眠，报告的 wallMs 与 durationMs 差值会标出。
- release／host 报告绑定 Mac 平台指纹（见 _gogaku_delivery.platform_fingerprints），
  同版本只递增构建号、Mac 侧未改动时可沿用；fast 每个构建都要重跑。
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
from _gogaku_delivery import (DeliveryError, platform_fingerprints, sha256, source_fingerprint,
                              test_fingerprint, validate_package, working_tree_dirty)
from _gogaku_verification import HOST_PROFILES, POLICY_VERSION, PROFILE_CHECKS, validate_ctest_result

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
        rejects('{"version": "0.1.0-rc.1", "buildNumber": 2}', '已取消的 rc 预发布段')
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
        build.require_clean_allowed('final', True)
        problems.append('未拒绝：dirty 定版构建')
    except SystemExit:
        pass
    # 两套已安装应用版本一致性（存在时）。
    consistency = []
    import plistlib
    apps = [INSTALLED_INPUT_APP, INSTALLED_SETTINGS_APP]
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
    detail = f"version.json={meta['version']} 构建{meta['buildNumber']}；拒绝路径 {rejected}/8；" + '；'.join(consistency)
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
        digest = sha256(data)
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
        digest = sha256(source)
        if digest != expected:
            problems.append(f'依赖数据哈希不符：{name}')
    if problems:
        return FAIL, '；'.join(problems), None
    return PASS, '；'.join(notes) + f'；依赖锁 {len(lock_data["artifacts"])} 项一致', None


def check_core_tests(ctx):
    """共享核心：Release 构建＋ctest 全量（含 ABI、事件轨迹、质量、fuzz 冒烟）。"""
    result = sh(['cmake', '-S', 'shared/GogakuCore', '-B', ctx['core_dir'],
                 '-G', 'Ninja', '-DCMAKE_BUILD_TYPE=Release', f'-DGOGAKU_DEPS={CACHE}'])
    if result.returncode != 0:
        return FAIL, 'cmake 配置失败：' + result.stderr[-400:], None
    result = sh(['cmake', '--build', ctx['core_dir'], '-j', str(ctx['jobs'])])
    if result.returncode != 0:
        return FAIL, '核心构建失败：' + (result.stdout[-300:] + result.stderr[-300:]), None
    env = {'GOGAKU_CORE_TEST_DATA': str(CACHE / 'data')} if (CACHE / 'data').exists() else {}
    result = sh(['ctest', '--test-dir', ctx['core_dir'], '--output-on-failure', '--no-tests=error'], env=env, timeout=1200)
    evidence = ctx.evidence('core-ctest.log', result.stdout + result.stderr)
    problems = validate_ctest_result(result.returncode, result.stdout + result.stderr)
    if problems:
        return FAIL, 'ctest 未完整通过：' + '；'.join(problems), evidence
    return PASS, 'ctest 全量通过，无跳过／未运行项', evidence


def check_swift_tests(ctx):
    """Swift 回归：Release 配置（与交付构建一致；Debug 结果不作为通过证据）。"""
    result = sh(['swift', 'test', '-c', 'release', '-j', str(ctx['jobs'])], timeout=1800,
                cwd=ROOT / 'macos')  # Swift 包根已迁至 macos/
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


def check_translation_data(ctx):
    """通用测试集冻结身份、数量、审阅分组与资源许可检查；不调用在线服务。"""
    result = sh(['python3', 'scripts/validate-translation-data.py'], timeout=120)
    evidence = ctx.evidence('translation-data.log', result.stdout + result.stderr)
    if result.returncode != 0:
        return FAIL, f'翻译数据检查失败（exit={result.returncode}）', evidence
    return PASS, '通用翻译数据与资源正负例回归通过（不代表译文质量通过）', evidence


def check_verification_contracts(ctx):
    """验证工具自身的离线负例，防止错误身份／旧 GUI／跳过被判为通过。"""
    result = sh(['python3', '-m', 'unittest', 'scripts.test_verification'], timeout=120)
    evidence = ctx.evidence('verification-contracts.log', result.stdout + result.stderr)
    if result.returncode != 0:
        return FAIL, f'验证合同回归失败（exit={result.returncode}）', evidence
    return PASS, '验证工具的离线正负例通过', evidence


def check_delivery_contracts(ctx):
    """双端交付合同自测：更新清单签名、Windows 组装布局、pkg 事务脚本与
    已移除本地模型的静态回归。不联网、不安装、不触碰真实用户目录。"""
    import base64
    import subprocess as sp
    problems, notes = [], []
    result = sh(['python3', '-m', 'unittest', 'scripts.test_delivery_pipeline'], timeout=300)
    if result.returncode != 0:
        problems.append('交付流水线负例失败：' + (result.stdout + result.stderr)[-500:])
    else:
        notes.append('交付流水线身份／报告／发布负例通过')
    result = sh(['python3', '-m', 'unittest', 'scripts.test_build_paths'], timeout=120)
    if result.returncode != 0:
        problems.append('隔离构建路径回归失败：' + (result.stdout + result.stderr)[-500:])
    else:
        notes.append('隔离构建路径回归通过')
    result = sh(['python3', 'scripts/make-update-manifest.py', '--self-test'], timeout=300)
    if result.returncode != 0:
        problems.append('更新清单 self-test 失败：' + (result.stdout + result.stderr)[-300:])
    else:
        notes.append('更新清单签名/篡改拒绝通过')
    result = sh(['python3', 'scripts/build-win-app.py', '--self-test'], timeout=120)
    if result.returncode != 0:
        problems.append('Windows 组装 self-test 失败：' + (result.stdout + result.stderr)[-300:])
    else:
        notes.append('Windows 安装器布局/iss 渲染通过')
    script = ROOT / 'macos/packaging/pkg-postinstall.sh'
    if not script.exists():
        problems.append('缺少 pkg 事务 postinstall 模板')
    else:
        result = sp.run(['bash', '-n', str(script)], text=True, capture_output=True)
        if result.returncode != 0:
            problems.append('pkg postinstall 语法错误：' + result.stderr[-200:])
        else:
            notes.append('pkg postinstall 语法通过')
    if (ROOT / 'scripts/package-macos-dmg.py').exists():
        problems.append('DMG 打包脚本仍在（本轮 Mac 只交付 pkg）')
    config_path = ROOT / 'resources/update/config.json'
    try:
        config = json.loads(config_path.read_text())
        assert config.get('schema') == 1
        keys = config.get('trustedKeys') or []
        assert keys and all(len(base64.b64decode(k['publicKey'])) == 32 for k in keys)
        notes.append(f"更新源配置 {len(keys)} 个可信公钥"
                     + ('（已配置仓库）' if config.get('owner') and config.get('repo') else '（仓库留空＝未配置）'))
    except Exception as error:
        problems.append(f'更新源配置非法：{error}')
    forbidden = ('learningBeamSize', 'quickmt_worker', 'normalizedBackend', 'small100_worker')
    hits = []
    for path in (ROOT / 'macos/Sources').rglob('*.swift'):
        text = path.read_text(errors='ignore')
        for token in forbidden:
            if token in text:
                hits.append(f'{path.relative_to(ROOT)}:{token}')
    if hits:
        problems.append('产品源码仍引用本地模型：' + ', '.join(hits[:5]))
    else:
        notes.append('产品源码无本地模型引用')
    evidence = ctx.evidence('delivery-contracts.log', '\n'.join(notes + problems))
    if problems:
        return FAIL, '；'.join(problems), evidence
    return PASS, '；'.join(notes), evidence


def check_clean_build(ctx):
    """干净构建：全新构建根（native/core/swift 互不 reuse）组装安装包，产物身份
    与当前提交绑定。依赖缓存只读复用（不清除用户缓存）。"""
    build_root = ROOT / '.build/verify-clean'
    if build_root.exists():
        shutil.rmtree(build_root)
    result = sh(['python3', 'scripts/build.py', '--configuration', 'release', '--channel', CHANNEL],
                env={'GOGAKU_BUILD_ROOT': str(build_root)}, timeout=3600)
    evidence = ctx.evidence('clean-build.log', result.stdout + result.stderr)
    if result.returncode != 0:
        return FAIL, '构建失败：' + result.stdout.strip().splitlines()[-1][:200], evidence
    identity = ROOT / 'dist' / ('build-identity-dev.json' if CHANNEL == 'dev' else 'build-identity.json')
    if not identity.exists():
        return FAIL, '构建未产出 dist/build-identity.json', evidence
    data = json.loads(identity.read_text())
    head = sh(['git', 'rev-parse', 'HEAD']).stdout.strip()
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
    names = {DIST_INPUT_APP.name, DIST_SETTINGS_APP.name}
    if (data.get('channel') != CHANNEL or data.get('sourceSha256') != source_fingerprint(ROOT)
            or set(data.get('apps', {})) != names):
        return FAIL, '干净构建身份／源码／通道与目标不符', evidence
    return PASS, (f"{data['fullVersion']} 构建{data['buildNumber']} 提交 {head[:12]}"
                  f"（两套应用各 {len(data['apps'][DIST_INPUT_APP.name]['files'])}／"
                  f"{len(data['apps'][DIST_SETTINGS_APP.name]['files'])} 个运行时文件已哈希）"), evidence


def check_bundle(ctx):
    """安装包检查：签名、依赖闭包、包内核心与 helper 冒烟。"""
    if not DIST_INPUT_APP.exists():
        return BLOCK, f'缺少 {DIST_INPUT_APP.relative_to(ROOT)}；先构建再检查（--channel {CHANNEL}）', None
    report_path = ctx.evidence_path('bundle-check.json')
    result = sh(['python3', 'scripts/check-bundle.py',
                 '--input-app', str(DIST_INPUT_APP), '--settings-app', str(DIST_SETTINGS_APP),
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
    # 与 check_swift_tests 共用 macos/.build，询问 SwiftPM 而非硬编码架构路径。
    result = sh(['swift', 'build', '-c', 'release', '--show-bin-path'], cwd=ROOT / 'macos')
    if result.returncode != 0 or not result.stdout.strip():
        return BLOCK, '无法确定 Swift Release 构建目录', None
    swift_bin = Path(result.stdout.strip())
    modules, objects_dir = swift_bin / 'Modules', swift_bin / 'GogakuKit.build'
    if not modules.exists() or not objects_dir.exists():
        return BLOCK, '缺少 macos/.build 的 Release 产物（先运行 fast 档）', None
    binary = ROOT / '.build/render-panel-verify'
    objects = sorted(str(p) for p in objects_dir.rglob('*.o'))
    if not objects:
        return BLOCK, 'GogakuKit 目标文件缺失', None
    compile_cmd = ['swiftc', 'probes/render-candidate-panel.swift',
                   'macos/Sources/GogakuInput/CandidatePanel.swift',
                   'macos/Sources/GogakuInput/CandidatePanelTheme.swift',
                   '-I', str(modules),
                   '-I', 'macos/Sources/CGogakuCore', '-I', 'macos/Sources/CGogakuEngine', '-I', 'macos/Sources/CSQLite',
                   '-L', str(ctx['core_dir']), '-lgogaku_core',
                   '-L', str(ROOT / '.build/native'), '-lGogakuEngine', '-lsqlite3',
                   '-Xlinker', '-rpath', '-Xlinker', str(ctx['core_dir']),
                   '-Xlinker', '-rpath', '-Xlinker', str(ROOT / '.build/native'),
                   *objects, '-o', binary]
    result = sh(compile_cmd, timeout=600)
    if result.returncode != 0:
        return FAIL, '渲染工具编译失败：' + result.stderr[-300:], None
    result = sh([binary], timeout=600, capture=True,
                env={'GOGAKU_RENDER_OUTPUT_DIR': str(ctx._dir)})
    evidence = ctx.evidence('panel-render.log', result.stdout + result.stderr)
    if result.returncode != 0:
        return FAIL, f'渲染检查失败（exit={result.returncode}）', evidence
    summaries = re.findall(r'^候选窗渲染比对：(\d+) 项检查，失败 (\d+) — (PASS|FAIL)$',
                           result.stdout, re.MULTILINE)
    if len(summaries) != 1:
        return FAIL, '渲染报告缺少唯一的完整汇总', evidence
    count, failures, verdict = summaries[0]
    prefix = result.stdout.split('候选窗渲染比对：', 1)[0]
    passed = re.findall(r'^\s+ok\s+.+$', prefix, re.MULTILINE)
    if (int(count) < 53 or int(failures) != 0 or verdict != 'PASS'
            or len(passed) != int(count) or re.search(r'^\s*FAIL\b', result.stdout, re.MULTILINE)):
        return FAIL, '渲染逐项结果、数量或汇总未完整通过', evidence
    return PASS, f'渲染检查通过（{count} 项）', evidence


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
    result = sh(['cmake', '-S', 'shared/GogakuCore', '-B', asan_dir, '-G', 'Ninja',
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
    env = dict(os.environ)
    env.update({'GOGAKU_CORE_TEST_DATA': str(CACHE / 'data'),
                # macOS 的 ASan 不支持 detect_leaks；强行开启会 SIGABRT。
                'ASAN_OPTIONS': 'detect_leaks=0',
                'UBSAN_OPTIONS': 'print_stacktrace=1:halt_on_error=1'})
    total = 2000 if ctx['quick'] else 100000
    # 分片：第 k 片用种子 20261031+k，各自独立临时目录；总序列数不变。
    shards = max(1, min(ctx.get('asan_shards') or 1, total))
    base_seed = 20261031
    counts = [total // shards + (1 if k < total % shards else 0) for k in range(shards)]
    deadline = time.monotonic() + (600 if ctx['quick'] else 14400)
    procs = []
    for k, count in enumerate(counts):
        log = ctx.evidence_path(f'asan-ubsan-shard-{k}.log')
        stream = open(log, 'w')
        procs.append((k, count, log, stream, subprocess.Popen(
            [str(binary), str(base_seed + k), str(count)], cwd=ROOT, env=env,
            stdout=stream, stderr=subprocess.STDOUT)))
    failures, done = [], 0
    for k, count, log, stream, proc in procs:
        try:
            code = proc.wait(timeout=max(1, deadline - time.monotonic()))
        except subprocess.TimeoutExpired:
            for *_, other in procs:
                other.kill()
            code = 'timeout'
        stream.close()
        text = Path(log).read_text(errors='replace')
        # fuzz 全部输出走 stderr（fprintf）；完成判定看每片计数与 PASS。
        if code != 0:
            failures.append(f'分片 {k}（种子 {base_seed + k}）exit={code}')
        elif f'{count} 序列' not in text or '— PASS' not in text:
            failures.append(f'分片 {k} 无完成计数输出')
        else:
            done += count
    summary = [f'ASan＋UBSan {shards} 片并行，种子 {base_seed}–{base_seed + shards - 1}，'
               f'完成 {done}/{total} 序列']
    for k, _, log, _, _ in procs:
        summary.append(f'--- 分片 {k} ---\n' + Path(log).read_text(errors='replace')[-2000:])
    evidence = ctx.evidence('asan-ubsan.log', '\n'.join(summary))
    if failures:
        return FAIL, '插桩运行失败（中断或报错均不算通过）：' + '；'.join(failures), evidence
    if done != total:
        return FAIL, f'完成序列 {done} ≠ {total}；不视为通过', evidence
    return PASS, f'{total} 随机序列 ASan＋UBSan 无错误（{shards} 片并行）' + \
        ('（quick 冒烟，不满足十万门槛）' if ctx['quick'] else ''), evidence


def check_install_preflight(ctx):
    """安装恢复预检：dist 双包签名、双包版本一致、备份不再以可启动 .app 暴露。
    真实安装/恢复由 scripts/manage-install.py install／recover 在用户授权下执行
    （安装后自动核对运行时哈希），不在本档位隐式接管。"""
    import plistlib
    problems = []
    apps = [DIST_INPUT_APP, DIST_SETTINGS_APP]
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
    installed = INSTALLED_INPUT_APP.exists()
    settings_app = INSTALLED_SETTINGS_APP.exists()
    if not installed or not settings_app:
        missing = []
        if not installed:
            missing.append(str(INSTALLED_INPUT_APP).replace(Path.home().__str__(), '~'))
        if not settings_app:
            missing.append('~/Applications/Gogaku Settings.app')
        return BLOCK, '输入法未安装（缺 ' + '、'.join(missing) + '）；先构建并安装', None
    full = ctx.get('profile') == 'host-full'
    plan = (
        f"{ctx.get('profile') or 'host'} 档位需要 --yes 显式确认（将向系统注入真实按键并占用桌面）。确认后逐项执行：\n"
        '  - host-identity：安装件身份与 version.json 一致性核对\n'
        f'  - host-matrix-round-1{"／round-2" if full else ""}：probes/validate-real-hosts.py --hosts {HOST_MATRIX_HOSTS} --iterations 200\n'
        + ('  - orca-shift：probes/first_key_regression.py --hosts orca-pty --iterations 200 --enable-validation（逐事件核对按下／释放、组合变化、插字次数、PTY 字节）\n' if full else '')
        + '  - performance：probes/measure-imk-latency.py --events 10000（约万次真实事件；计时期间不并行构建）\n'
        + ('  - stability：probes/stability-soak.py --minutes 120（两小时浸泡，逐轮报告＋内存趋势）\n' if full else '')
        + '  - native-gui：设置七页 × ' + ('两种窗口尺寸' if full else '默认 900×620') + ' × 浅／深外观的真实点击／键盘导航验收（需人工核对后归档当前身份的逐项证据）'
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
    binary = INSTALLED_INPUT_APP / 'Contents/MacOS/GogakuInput'
    apps = [INSTALLED_INPUT_APP, INSTALLED_SETTINGS_APP]
    for app in apps:
        plist = app / 'Contents/Info.plist'
        if not plist.exists():
            problems.append(f'{app} 缺少 Info.plist')
            continue
        info = plistlib.loads(plist.read_bytes())
        expected_id = ('org.gogaku.inputmethod' if app == INSTALLED_INPUT_APP else 'org.gogaku.settings')
        expected_id += '.dev' if CHANNEL == 'dev' else ''
        if info.get('CFBundleIdentifier') != expected_id:
            problems.append(f'{app.name} bundle ID 与 {CHANNEL} 通道不符')
        identity_path = app / 'Contents/Resources/build-identity.json'
        try:
            identity = json.loads(identity_path.read_text())
            if (identity.get('sourceSha256') != source_fingerprint(ROOT)
                    or identity.get('channel') != CHANNEL
                    or identity.get('fullVersion') != expected_release[0]
                    or str(identity.get('buildNumber')) != expected_release[1]):
                problems.append(f'{app.name} 包内源码／通道／版本身份过期')
        except (OSError, ValueError, AttributeError):
            problems.append(f'{app.name} 缺少可读的包内构建身份')
        got = (info.get('CFBundleShortVersionString'), str(info.get('CFBundleVersion')))
        expected = (str(expected_release[0]).split('-', 1)[0], expected_release[1])
        if got != expected:
            problems.append(f'{app.name} 版本 {got} ≠ version.json {expected}')
        else:
            notes.append(f'{app.name} {got[0]} b{got[1]}')
    sha = sha256(binary) if binary.exists() else None
    if sha is None:
        problems.append('输入法主二进制不存在：' + str(binary))
    return '；'.join(notes), problems, sha


def _probe_module(name):
    """只加载探针的纯数据／校验函数，不调用其 main 或真实桌面操作。"""
    import importlib.util
    probe_dir = str(ROOT / 'probes')
    if probe_dir not in sys.path:
        sys.path.insert(0, probe_dir)
    spec = importlib.util.spec_from_file_location('gogaku_verify_' + name,
                                                 ROOT / 'probes' / (name + '.py'))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def _host_coverage_problems(report, hosts, iterations, evidence_path, strict):
    """按探针同一份计划核对全部宿主、组和逐轮证据，不能只信 failures=0。"""
    from collections import Counter
    fkr = _probe_module('first_key_regression')
    expected = fkr.build_plan(hosts, iterations)
    matrix = report.get('firstKeyMatrix') if strict else report
    if not isinstance(matrix, dict):
        return ['缺少完整首键矩阵']
    problems = []
    expected_schema = 'gogaku.real-host-matrix.v2' if strict else 'gogaku.first-key-matrix.v1'
    if report.get('schema') != expected_schema:
        problems.append('宿主报告 schema 不符')
    if not isinstance(report.get('panelState'), dict) or report['panelState'].get('enabled') is not True:
        problems.append('缺少真实候选窗／逐事件状态证据')
    plan = matrix.get('plan')
    if not isinstance(plan, dict) or any(plan.get(key) != expected[key] for key in
                                        ('sha256', 'hosts', 'iterations', 'confirmations', 'postKeys')):
        problems.append('首键计划与本次必需宿主／轮次不符')
    checks = matrix.get('checks')
    if (type(matrix.get('failures')) is not int or matrix['failures'] != 0
            or not isinstance(checks, list) or not checks
            or any(not isinstance(c, dict) or c.get('ok') is not True for c in checks)):
        problems.append('首键矩阵未逐项通过')
    else:
        event_groups = {c.get('group') for c in checks if c.get('phase') == 'panel'}
        if not {g['id'] for g in expected['groups']} <= event_groups:
            problems.append('部分组缺少逐事件／面板检查')
    groups = matrix.get('groups')
    expected_ids = {g['id'] for g in expected['groups']}
    if (not isinstance(groups, list) or any(not isinstance(g, dict) for g in groups)
            or len(groups) != len(expected_ids) or {g.get('id') for g in groups} != expected_ids):
        return problems + ['宿主矩阵组缺失／重复／不符']
    totals = {}
    for group in groups:
        warmup = group.get('warmup')
        if (type(warmup) is not int or warmup < 0 or type(group.get('iterations')) is not int
                or group['iterations'] != iterations):
            problems.append('矩阵组轮次非法：' + str(group.get('id')))
            continue
        total = iterations + warmup
        if (any(type(group.get(k)) is not int for k in ('ran', 'passed', 'failed'))
                or group['ran'] != total or group['passed'] != total or group['failed'] != 0):
            problems.append('矩阵组未完成全部轮次：' + group['id'])
        totals[group['id']] = total
    try:
        records = [json.loads(line) for line in Path(evidence_path).read_text().splitlines() if line.strip()]
        actual = Counter()
        for row in records:
            if (not isinstance(row, dict) or row.get('group') not in totals
                    or type(row.get('iteration')) is not int or row.get('ok') is not True):
                raise ValueError('逐轮证据字段非法')
            actual[(row['group'], row['iteration'])] += 1
        wanted = Counter({(group, index): 1 for group, total in totals.items() for index in range(total)})
        if actual != wanted:
            problems.append('逐轮证据缺失／重复或未完成')
    except (OSError, ValueError):
        problems.append('逐轮证据缺失或不可读')
    if strict:
        probe = _probe_module('validate-real-hosts')
        if report.get('strictScenarios') != [s['id'] for s in probe.SCENARIOS]:
            problems.append('严格宿主场景清单不符')
        targets = {f'{host}/{target}' for host in hosts for target in fkr.TARGETS[host]}
        if not isinstance(report.get('hosts'), list) or set(report['hosts']) != targets:
            problems.append('实际宿主／字段覆盖不完整')
        labels = {c.get('check') for c in report.get('checks', []) if isinstance(c, dict)}
        if any(not any(label.startswith(target + ': ' + scenario['label']) for label in labels
                       if isinstance(label, str)) for target in targets for scenario in probe.SCENARIOS):
            problems.append('严格宿主场景逐项证据不完整')
    return problems


def _host_json_problems(report_path, expect_sha, min_checks=1, *, hosts=None,
                        iterations=200, evidence_path=None, strict=False):
    """核对宿主报告：结果文件可读、完成数量达标、失败为 0、安装件身份一致。
    缺证据按 blocked 处理（返回 None 表示需 blocked）。"""
    if not Path(report_path).exists():
        return None
    try:
        report = json.loads(Path(report_path).read_text())
    except json.JSONDecodeError:
        return None
    problems = []
    if not isinstance(report, dict):
        return ['宿主报告必须是对象']
    checks = report.get('checks')
    failures = report.get('failures')
    if not isinstance(checks, list) or type(failures) is not int:
        problems.append('报告缺少合法的 checks／failures 字段')
    else:
        if len(checks) < min_checks:
            problems.append(f'检查数 {len(checks)} < 门槛 {min_checks}')
        if failures != 0 or any(not isinstance(c, dict) or c.get('ok') is not True for c in checks):
            problems.append(f'失败 {failures} 项或逐项结果未明确通过')
    identity = report.get('inputSource')
    sha = identity.get('installedSHA256') if isinstance(identity, dict) else None
    if not expect_sha or sha != expect_sha:
        problems.append(f"报告安装件身份 {str(sha)[:12]} ≠ 当前安装件 {str(expect_sha)[:12]}")
    skipped = report.get('skipped', [])
    if not isinstance(skipped, list) or skipped:
        problems.append('存在跳过宿主或 skipped 字段非法')
    if hosts is not None:
        problems.extend(_host_coverage_problems(report, hosts, iterations, evidence_path, strict))
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
                 '--hosts', HOST_MATRIX_HOSTS, '--iterations', '200', '--enable-validation',
                 '--report', report_path, '--evidence', evidence_path], timeout=14400)
    log = ctx.evidence(f'host-matrix-round-{round_no}.log', result.stdout + result.stderr)
    problems = _host_json_problems(report_path, expect_sha, hosts=HOST_MATRIX_HOSTS.split(','),
                                    evidence_path=evidence_path, strict=True)
    if problems is None:
        return BLOCK, f'第 {round_no} 轮报告缺失或不可读（exit={result.returncode}，见日志）', log
    if result.returncode != 0:
        return FAIL, f'第 {round_no} 轮进程失败或前台身份断言中止（exit={result.returncode}）', log
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
    evidence_path = ctx.evidence_path('orca-shift.jsonl')
    result = sh(['python3', 'probes/first_key_regression.py', '--hosts', 'orca-pty',
                 '--iterations', '200', '--enable-validation', '--report', report_path,
                 '--evidence', evidence_path], timeout=14400)
    log = ctx.evidence('orca-shift.log', result.stdout + result.stderr)
    problems = _host_json_problems(report_path, expect_sha, hosts=['orca-pty'],
                                    evidence_path=evidence_path)
    if problems is None:
        return BLOCK, 'Orca Shift 专项报告缺失或不可读', log
    if result.returncode != 0:
        return FAIL, f'Orca Shift 进程未正常完成（exit={result.returncode}）', log
    if problems:
        return FAIL, 'Orca Shift 专项未通过：' + '；'.join(problems), log
    report = json.loads(Path(report_path).read_text())
    return PASS, f'Orca Shift 专项通过（{len(report["checks"])} 项检查，含逐事件核对）', log


def _performance_problems(report, samples_path, expect_sha):
    """读取本轮原始样本，复用探针的汇总与门槛实现重新判定。"""
    import math
    if not isinstance(report, dict) or report.get('schema') != 'gogaku.imk-latency.v1':
        return ['性能报告 schema 不符']
    try:
        samples = json.loads(Path(samples_path).read_text())
        declared = report.get('samplesFile')
        if not isinstance(declared, str) or Path(declared).resolve() != Path(samples_path).resolve():
            return ['性能报告未绑定本轮样本文件']
    except (OSError, ValueError):
        return ['性能原始样本缺失或不可读']
    if (not isinstance(samples, list) or len(samples) < 10000
            or type(report.get('sampleCount')) is not int or report['sampleCount'] != len(samples)):
        return ['性能有效样本未达到一万或数量不符']
    if any(not isinstance(s, dict) or type(s.get('callbackNs')) not in (int, float)
           or not math.isfinite(s['callbackNs']) or s['callbackNs'] < 0 for s in samples):
        return ['性能样本缺少合法回调耗时']
    identity = report.get('inputSource')
    artifacts = identity.get('artifacts', []) if isinstance(identity, dict) else []
    if not expect_sha or not isinstance(artifacts, list) or not any(
            isinstance(a, dict) and a.get('path') == 'Contents/MacOS/GogakuInput'
            and a.get('sha256') == expect_sha for a in artifacts):
        return ['性能报告安装件身份不符']
    probe = _probe_module('measure-imk-latency')
    summary = probe.summarize(samples)
    if report.get('summary') != summary:
        return ['性能汇总与原始样本不符']
    acceptance = probe.evaluate_report({**report, 'summary': summary})
    if acceptance['passed'] is not True or report.get('acceptance') != acceptance:
        return ['性能重新判定未通过或 acceptance 不符']
    return []


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
    try:
        report = json.loads(Path(report_path).read_text())
    except (OSError, ValueError):
        return FAIL, '性能报告不可读', log
    problems = _performance_problems(report, samples_path, ctx.get('installed_sha'))
    if result.returncode != 0:
        problems.append(f'性能进程未完成（exit={result.returncode}）')
    if problems:
        return FAIL, '性能未通过：' + '；'.join(problems), log
    return PASS, f'性能门槛通过（{report["sampleCount"]} 条原始样本，当前安装件）', log


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
    if result.returncode != 0:
        problems.append(f'进程未正常完成（exit={result.returncode}）')
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


GUI_PAGES = ('learning-translation', 'normal-input', 'custom-words', 'skin',
             'shortcuts', 'learning-privacy', 'learning-snippets')
GUI_SIZES = ((900, 620), (760, 520))
GUI_APPEARANCES = ('light', 'dark')


def gui_required_cells(profile):
    """host 短档抽查默认尺寸（14 项）；host-full 为七页×两尺寸×浅深全矩阵（28 项）。"""
    sizes = GUI_SIZES if profile != 'host' else GUI_SIZES[:1]
    return {(p, size, a) for p in GUI_PAGES for size in sizes for a in GUI_APPEARANCES}


def gui_problems(report, evidence_dir, expected, required=None):
    """人工验收证据的完整性／身份检查；不以截图存在代替人工实际操作。"""
    import hashlib
    if not isinstance(report, dict):
        return ['GUI 报告必须是对象']
    problems = []
    for key, value in expected.items():
        if report.get(key) != value:
            problems.append(f'GUI {key} 与当前身份不符')
    if report.get('pass') is not True:
        problems.append('GUI 总结不是明确通过')
    all_cells = gui_required_cells('host-full')
    expected_cells = required or all_cells
    seen = set()
    screens = report.get('screens')
    if not isinstance(screens, list):
        return problems + ['GUI 缺少逐项 screens 矩阵（七页×两尺寸×浅深）']
    for screen in screens:
        if not isinstance(screen, dict):
            problems.append('GUI 矩阵项不是对象')
            continue
        size = screen.get('size')
        if not isinstance(size, list) or len(size) != 2 or any(type(n) is not int for n in size):
            problems.append('GUI 窗口尺寸非法')
            continue
        cell = (screen.get('page'), tuple(size), screen.get('appearance'))
        if cell not in all_cells or cell in seen or screen.get('passed') is not True:
            problems.append('GUI 矩阵项未知／重复／未通过')
        seen.add(cell)
        name = screen.get('screenshot')
        if not isinstance(name, str) or not name:
            problems.append('GUI 缺少截图路径')
            continue
        path = (evidence_dir / name).resolve()
        if (not path.is_relative_to(evidence_dir.resolve()) or not path.is_file()
                or path.stat().st_size == 0):
            problems.append('GUI 截图缺失／空文件／路径越界')
        elif hashlib.sha256(path.read_bytes()).hexdigest() != screen.get('screenshotSha256'):
            problems.append('GUI 截图哈希不符')
    if not expected_cells <= seen or len(screens) != len(seen):
        problems.append('GUI 必需矩阵不完整（%d 项中缺 %d 项）'
                        % (len(expected_cells), len(expected_cells - seen)))
    return problems


def check_native_gui(ctx):
    evidence = ROOT / 'docs/validation/verify' / f'native-gui-acceptance-{CHANNEL}.json'
    if not evidence.is_file():
        return BLOCK, ('原生 GUI 未归档：七页×900×620／760×520×浅深，真实点击、键盘、'
                       '录制与应用选择并读回配置；逐项格式见 docs/release.md：' + str(evidence)), None
    # 绑定安装件哈希与 Mac 平台指纹；纯文档提交或只改 Windows 不使人工证据失效。
    mac = platform_fingerprints(ROOT)['macos']
    expected = {'channel': CHANNEL, 'installedSHA256': ctx.get('installed_sha'),
                'macosSourceSha256': mac['sourceSha256'], 'macosTestSha256': mac['testSha256']}
    if not expected['installedSHA256']:
        return BLOCK, '缺少当前安装件的已核验身份；先运行 host-identity', None
    try:
        profile = ctx.get('profile') or 'host-full'
        problems = gui_problems(json.loads(evidence.read_text()), evidence.parent, expected,
                                gui_required_cells(profile))
    except (OSError, ValueError, TypeError):
        return FAIL, 'GUI 证据不可读或类型非法', str(evidence)
    if problems:
        return FAIL, '；'.join(problems), str(evidence)
    return PASS, ('GUI 人工验收证据完整（%d 项，身份／截图已核对）'
                  % len(gui_required_cells(ctx.get('profile') or 'host-full'))), str(evidence)


# ── 档位定义 ──────────────────────────────────────────────────────────────

# 安装通道（--channel）：stable=Gogaku，dev=Gogaku Dev（bundle ID 带 .dev）。
# 两通道应用名/路径不同，检查按通道取路径；用户数据两通道共用。
CHANNEL = 'stable'
DIST_INPUT_APP = ROOT / 'dist/Gogaku.app'
DIST_SETTINGS_APP = ROOT / 'dist/Gogaku Settings.app'
INSTALLED_INPUT_APP = Path.home() / 'Library/Input Methods/Gogaku.app'
INSTALLED_SETTINGS_APP = Path.home() / 'Applications/Gogaku Settings.app'


def set_channel(name):
    global CHANNEL, DIST_INPUT_APP, DIST_SETTINGS_APP, INSTALLED_INPUT_APP, INSTALLED_SETTINGS_APP
    CHANNEL = name
    suffix = ' Dev' if name == 'dev' else ''
    DIST_INPUT_APP = ROOT / f'dist/Gogaku{suffix}.app'
    DIST_SETTINGS_APP = ROOT / f'dist/Gogaku Settings{suffix}.app'
    INSTALLED_INPUT_APP = Path.home() / 'Library/Input Methods' / f'Gogaku{suffix}.app'
    INSTALLED_SETTINGS_APP = Path.home() / 'Applications' / f'Gogaku Settings{suffix}.app'


RUNNERS = {
    'version': check_version, 'resources': check_resources,
    'core-tests': check_core_tests, 'swift-tests': check_swift_tests,
    'translation-data': check_translation_data,
    'verification-contracts': check_verification_contracts,
    'delivery-contracts': check_delivery_contracts,
    'clean-build': check_clean_build, 'bundle-check': check_bundle,
    'quality': check_quality, 'render': check_render,
    'data-reliability': check_data_reliability, 'asan-ubsan': check_asan_ubsan,
    'install-preflight': check_install_preflight,
    'host-plan': check_host_plan, 'host-identity': check_host_identity,
    'host-matrix-round-1': lambda ctx: check_host_matrix_round(ctx, 1),
    'host-matrix-round-2': lambda ctx: check_host_matrix_round(ctx, 2),  # 仅 host-full
    'orca-shift': check_orca_shift, 'performance': check_host_performance,
    'stability': check_host_stability, 'native-gui': check_native_gui,
}
# 执行器与发布消费者共用一份策略；报告不能自己削减必需项。
PROFILES = {profile: [(name, required, RUNNERS[name]) for name, required in checks]
            for profile, checks in PROFILE_CHECKS.items()}


class Ctx:
    def __init__(self, args):
        self['core_dir'] = ROOT / '.build/core'
        self['jobs'] = args.jobs
        self['asan_shards'] = args.asan_shards
        self['profile'] = args.profile
        self['quick'] = args.quick
        self['yes'] = args.yes
        self._dir = EVIDENCE_DIR / f'{args.profile}-{time.strftime("%Y%m%d-%H%M%S")}'
        self._dir.mkdir(parents=True, exist_ok=True)

    def __setitem__(self, k, v):
        setattr(self, k, v)

    def __getitem__(self, k):
        return getattr(self, k)

    def get(self, k, default=None):
        return getattr(self, k, default)

    def evidence_path(self, name):
        return self._dir / name

    def evidence(self, name, text):
        path = self._dir / name
        path.write_text(text or '')
        return str(path)


def keep_awake():
    """macOS：本进程存活期间阻止空闲／显示器睡眠；合盖且无外接显示器时仍会睡眠。"""
    if sys.platform != 'darwin' or os.environ.get('GOGAKU_NO_CAFFEINATE') or not shutil.which('caffeinate'):
        return None
    return subprocess.Popen(['caffeinate', '-dims', '-w', str(os.getpid())],
                            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def identity_snapshot():
    return {'source': source_fingerprint(ROOT), 'tests': test_fingerprint(ROOT),
            'platforms': platform_fingerprints(ROOT)}


def identity_unchanged(profile, before, after):
    """fast 绑定全量指纹；release／host 只绑定 Mac 平台指纹（只改 Windows 不影响）。"""
    if profile == 'fast':
        return before == after
    return before['platforms']['macos'] == after['platforms']['macos']


def main():
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--profile', choices=sorted(PROFILES), required=True)
    parser.add_argument('--channel', choices=['stable', 'dev'], default='stable',
                        help='检查哪个安装通道的包（dev=Gogaku Dev，bundle ID 带 .dev）')
    parser.add_argument('--jobs', type=int, default=2)
    parser.add_argument('--asan-shards', type=int, default=max(1, min(8, (os.cpu_count() or 2) // 2)),
                        help='十万序列 ASan 分几片并行（默认核数一半、最多 8；quick 同样分片）')
    parser.add_argument('--quick', action='store_true',
                        help='ASan/UBSan 用 2000 序列冒烟（不满足十万序列门槛，仅开发用）')
    parser.add_argument('--yes', action='store_true',
                        help='host 档位：显式确认注入真实按键（不确认则只输出计划并记 blocked）')
    parser.add_argument('--only', default='', help='只运行指定检查（逗号分隔），其余记 skipped')
    parser.add_argument('--report', default='')
    args = parser.parse_args()
    set_channel(args.channel)

    awake = keep_awake()
    ctx = Ctx(args)
    only = {name.strip() for name in args.only.split(',') if name.strip()}
    unknown = only - {name for name, _, _ in PROFILES[args.profile]}
    if unknown:
        parser.error('--only 中存在未知检查：' + ', '.join(sorted(unknown)))
    started = time.strftime('%Y-%m-%dT%H:%M:%S%z')
    start_identity = identity_snapshot()
    start_source, start_tests = start_identity['source'], start_identity['tests']
    results = []
    for name, required, runner in PROFILES[args.profile]:
        if only and name not in only:
            results.append({'name': name, 'required': required, 'status': SKIP,
                            'detail': '未选中（--only）', 'durationMs': 0, 'evidence': None})
            continue
        t0, w0 = time.monotonic(), time.time()
        try:
            # 当前宿主探针固定 stable；不允许 dev 报告实际测到 stable。
            if args.profile in HOST_PROFILES and CHANNEL != 'stable':
                status, detail, evidence = BLOCK, '宿主探针尚未支持 dev 通道；未注入按键，不接受 stable 安装件代测', None
            elif (args.profile in HOST_PROFILES and name not in ('host-plan', 'host-identity')
                  and not ctx.get('host_identity_passed')):
                status, detail, evidence = BLOCK, '当前安装件身份未通过；未启动宿主探针', None
            else:
                status, detail, evidence = runner(ctx)
            if name == 'host-identity':
                ctx['host_identity_passed'] = status == PASS
        except Exception as e:  # 检查自身崩溃按失败计，不静默
            status, detail, evidence = FAIL, f'检查异常：{type(e).__name__}: {e}', None
        duration = int((time.monotonic() - t0) * 1000)
        wall = max(0, int((time.time() - w0) * 1000))
        if wall - duration > 60000:
            # macOS 单调时钟睡眠期间不走；差值大说明期间系统睡眠，结果本身不受影响。
            detail = f'{detail}（墙钟比运行时长多 {(wall - duration) // 60000} 分钟，期间疑似系统睡眠）'
        results.append({'name': name, 'required': required, 'status': status,
                        'detail': detail, 'durationMs': duration, 'wallMs': wall, 'evidence': evidence})
        print(f"[{status.upper():7s}] {name}（{duration}ms）：{detail}")

    summary = {s: sum(1 for r in results if r['status'] == s) for s in (PASS, FAIL, SKIP, BLOCK)}
    required_bad = [r for r in results if r['required'] and r['status'] != PASS]
    identity_stable = identity_unchanged(args.profile, start_identity, identity_snapshot())
    gate = not required_bad and identity_stable
    head = sh(['git', 'rev-parse', 'HEAD']).stdout.strip() or 'no-git'
    dirty = working_tree_dirty(ROOT)
    artifacts = {}
    artifact_error = None
    suffix = '-dev' if CHANNEL == 'dev' else ''
    version = json.loads(VERSION_FILE.read_text())
    names = {
        'macos': ROOT / f'dist/Gogaku-{version["version"]}-b{version["buildNumber"]}{suffix}.pkg',
        'windows': ROOT / f'dist/gogaku-win/Gogaku-{version["version"]}-b{version["buildNumber"]}{suffix}-windows-x64-setup.exe',
    }
    if any(path.is_file() for path in names.values()):
        try:
            artifacts = {platform: validate_package(path, platform, CHANNEL)['artifact']
                         for platform, path in names.items()}
        except DeliveryError as error:
            artifact_error = str(error)
    report = {
        'policyVersion': POLICY_VERSION, 'runIdentityStable': identity_stable,
        'profile': args.profile, 'channel': CHANNEL, 'quick': args.quick,
        'sourceSha256': start_source, 'testSha256': start_tests,
        'platformFingerprints': start_identity['platforms'], 'artifacts': artifacts,
        'artifactError': artifact_error, 'startedAt': started,
        'finishedAt': time.strftime('%Y-%m-%dT%H:%M:%S%z'),
        'commit': head, 'dirty': dirty, 'arch': platform.machine(),
        'version': json.loads(VERSION_FILE.read_text()) if VERSION_FILE.exists() else None,
        'checks': results, 'summary': summary,
        'gate': {'passed': gate, 'notPassed': [r['name'] for r in required_bad]
                 + ([] if identity_stable else ['运行期间源码／测试身份改变'])},
        'keptAwake': awake is not None,
    }
    out = Path(args.report) if args.report else EVIDENCE_DIR / f'report-{args.profile}-{time.strftime("%Y%m%d-%H%M%S")}.json'
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps(report, ensure_ascii=False, indent=2) + '\n')
    print(f"\n摘要：passed={summary[PASS]} failed={summary[FAIL]} skipped={summary[SKIP]} "
          f"blocked={summary[BLOCK]}；本档位检查：{'通过' if gate else '未通过（' + '、'.join(report['gate']['notPassed']) + '）'}")
    print('发布就绪须由 publish-release.py 另行核对全部必需档位、当前双端包及收据；本档位通过不等于可发布。')
    if artifact_error:
        print('安装包身份未绑定：' + artifact_error)
    elif set(artifacts) != {'macos', 'windows'}:
        print('未绑定当前双端安装包，本报告仅为开发检查结果，不能用于发布。')
    print(f"报告：{out}")
    return 0 if gate else 1


if __name__ == '__main__':
    sys.exit(main())
