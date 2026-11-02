#!/usr/bin/env python3
"""核对开发包签名、动态依赖闭包，并运行包内引擎／拼写helper；不切换输入源。"""
import argparse
import ctypes as c
import hashlib
from datetime import datetime, timezone
import json
from pathlib import Path
import plistlib
import re
import subprocess
import uuid

ROOT = Path(__file__).resolve().parent.parent

class Candidate(c.Structure):
    _fields_ = [('text', c.c_char_p), ('index', c.c_size_t), ('raw_start', c.c_size_t), ('raw_length', c.c_size_t), ('completes', c.c_int)]

class Snapshot(c.Structure):
    _fields_ = [('raw', c.c_char_p), ('preedit', c.c_char_p), ('selected', c.c_char_p), ('commit', c.c_char_p),
                ('candidates', c.POINTER(Candidate)), ('count', c.c_size_t), ('total', c.c_size_t),
                ('page', c.c_size_t), ('selected_length', c.c_size_t), ('composing', c.c_int)]

def run(args):
    return subprocess.check_output([str(a) for a in args], text=True, stderr=subprocess.PIPE, timeout=30)

def inspect(app):
    run(['codesign', '--verify', '--deep', '--strict', app])
    contents = app / 'Contents'
    frameworks = contents / 'Frameworks'
    files = [*frameworks.glob('*.dylib'), *contents.joinpath('MacOS').iterdir(), *contents.joinpath('Helpers').iterdir()]
    libraries = []
    for binary in files:
        deps = [line.strip().split(' (')[0] for line in run(['otool', '-L', binary]).splitlines()[1:]]
        for dep in deps:
            if dep.startswith(('/usr/lib/', '/System/Library/')): continue
            assert dep.startswith('@rpath/'), (binary, dep)
            assert (frameworks / dep.removeprefix('@rpath/')).is_file(), (binary, dep)
        paths = re.findall(r'cmd LC_RPATH\n\s+cmdsize \d+\n\s+path (.*?) \(offset', run(['otool', '-l', binary]))
        assert all(p.startswith(('@loader_path', '@executable_path')) for p in paths), (binary, paths)
        libraries.append(str(binary.relative_to(contents)))
    binaries = [*contents.joinpath('MacOS').iterdir(), *contents.joinpath('Helpers').iterdir()]
    forbidden = (b'/tmp/gogaku-', b'gogaku-keys.log', b'gogaku-debug-enabled')
    for binary in binaries:
        image = binary.read_bytes()
        assert not any(marker in image for marker in forbidden), f'构建产物含旧输入日志代码：{binary}'
    return {'app': str(app), 'signature': 'valid_ad_hoc_local_only', 'dependencyClosure': 'package_and_system_only',
            'inputLogCode': 'absent', 'binaries': libraries,
            'binarySHA256': {str(p.relative_to(contents)): hashlib.sha256(p.read_bytes()).hexdigest() for p in files}}

def menu_icon(app):
    contents = app / 'Contents'
    info = plistlib.loads((contents / 'Info.plist').read_bytes())
    assert info.get('TISIconIsTemplate') is False, 'menu icon must be full-color to match system input-source caps'
    modes = info['ComponentInputModeDict']['tsInputModeListKey'].values()
    names = {info['tsInputMethodIconFileKey']}
    for mode in modes:
        names.update(mode[key] for key in ('tsInputModeMenuIconFileKey', 'tsInputModeAlternateMenuIconFileKey', 'tsInputModePaletteIconFileKey'))
    checks = {}
    for name in sorted(names):
        icon = contents / 'Resources' / name
        checks[name] = run(['/usr/bin/env', 'DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer',
                            'swift', ROOT / 'scripts/check-menu-icon.swift', icon]).strip()
    return checks

def engine_smoke(app):
    lib = c.CDLL(str(app / 'Contents/Frameworks/libGogakuEngine.dylib'))
    lib.ge_create.argtypes = [c.c_char_p, c.c_char_p, c.POINTER(c.c_void_p)]
    lib.ge_create.restype = c.c_int
    lib.ge_command.argtypes = [c.c_void_p, c.c_int, c.c_int64, c.POINTER(c.POINTER(Snapshot))]
    lib.ge_command.restype = c.c_int
    lib.ge_snapshot_free.argtypes = [c.POINTER(Snapshot)]
    lib.ge_destroy.argtypes = [c.c_void_p]
    data = app / 'Contents/Resources/EngineData'
    handle = c.c_void_p()
    assert lib.ge_create(str(data / 'sc.dict').encode(), str(data / 'zh_CN.lm').encode(), c.byref(handle)) == 0
    def command(op, arg=0):
        value = c.POINTER(Snapshot)()
        assert lib.ge_command(handle, op, arg, c.byref(value)) == 0
        result = {'raw': value.contents.raw.decode(), 'commit': value.contents.commit.decode(), 'composing': bool(value.contents.composing)}
        lib.ge_snapshot_free(value)
        return result
    try:
        for key in 'nihc': result = command(1, ord(key))
        assert result['raw'] == 'nihc'
        result = command(3, 0)
        assert result['commit'] == '你好' and not result['composing']
    finally: lib.ge_destroy(handle)
    return 'passed_factory_xiaohe_from_package'

def auto_pinyin_smoke(app):
    """设置应用通过自己的动态库与随包字典自动读音，不依赖开发缓存。"""
    lib = c.CDLL(str(app / 'Contents/Frameworks/libgogaku_core.dylib'))
    lookup = lib.gc_custom_pinyin_lookup
    lookup.argtypes = [c.c_char_p, c.c_char_p, c.POINTER(c.c_void_p)]
    lookup.restype = c.c_int
    release = c.CDLL(None).free
    release.argtypes = [c.c_void_p]
    dictionary = app / 'Contents/Resources/EngineData/sc.dict'
    assert dictionary.is_file(), '设置应用缺少自动读音所需的随包字典'
    results = {}
    for word, expected in [('极视角', "ji'shi'jiao"), ('角', 'jiao'), ('会议', "hui'yi")]:
        value = c.c_void_p()
        rc = lookup(str(dictionary).encode(), word.encode(), c.byref(value))
        try:
            assert rc == 0 and value.value, f'设置应用自动读音失败：{word} rc={rc}'
            actual = c.string_at(value).decode()
            assert actual == expected, (word, actual, expected)
            results[word] = actual
        finally:
            if value.value:
                release(value)
    return {'status': 'passed_from_settings_package', 'readings': results,
            'dictSHA256': hashlib.sha256(dictionary.read_bytes()).hexdigest()}

def spelling_smoke(app):
    helper = app / 'Contents/Helpers/GogakuTranslator'
    status = json.loads(run([helper, '--status']))
    request = {'protocolVersion': 1, 'id': str(uuid.uuid4()), 'stamp': {'session': str(uuid.uuid4()), 'focus': 1, 'composition': str(uuid.uuid4()), 'revision': 1, 'mode': 'learning', 'direction': 'enToZh'}, 'sourceID': 'spelling', 'source': '😀 metting ', 'resource': 'NSSpellChecker:en_US'}
    result = subprocess.run([str(helper), '--spell'], input=json.dumps(request) + '\n', text=True, capture_output=True, check=True, timeout=15)
    response = json.loads(result.stdout)
    assert uuid.UUID(response['id']) == uuid.UUID(request['id']) and response['source'] == request['source']
    assert any(i['location'] == 3 and i['length'] == 7 for i in response['issues'])
    return {'spelling': 'passed_utf16_from_package', 'systemResources': status}

def data_and_license_smoke(app):
    """英文词表／释义注释数据与随包许可文本：打包时哈希校验，缺失＝降级形态。"""
    import hashlib
    data = app / 'Contents/Resources/EngineData'
    licenses = app / 'Contents/Licenses'
    result = {}
    root = ROOT / 'resources'
    for filename, manifest_name in [('english-words.txt', 'english-wordlist-sources.json'), ('gloss.tsv', 'gloss-sources.json')]:
        bundled = data / filename
        manifest_path = root / manifest_name
        if bundled.exists():
            digest = hashlib.sha256(bundled.read_bytes()).hexdigest()
            expected = json.loads(manifest_path.read_text())['output_sha256']
            assert digest == expected, f'{filename} 哈希与来源清单不符'
            lines = bundled.read_text(encoding='utf-8').splitlines()
            result[filename] = {'sha256': digest, 'lines': len(lines)}
        else:
            result[filename] = 'absent_degraded'
    if (data / 'english-words.txt').exists() or (data / 'gloss.tsv').exists():
        for required in ['CC-BY-SA-4.0.txt', 'SCOWL-Copyright.txt', 'DATA-ATTRIBUTION.txt']:
            assert (licenses / required).is_file(), f'随包许可缺失 {required}'
        result['licenses'] = 'data_licenses_present'
    else:
        result['licenses'] = 'not_required_no_data'
    return result

def normal_core_smoke(app):
    """共享普通模式核心（ABI v2）：包内 dylib 完成 nihc→你好 事件轨迹。"""
    lib = c.CDLL(str(app / 'Contents/Frameworks/libgogaku_core.dylib'))
    assert lib.gc_abi_version() == 2, '共享核心 ABI 版本应为 2'

    class GcNormalConfig(c.Structure):
        _fields_ = [('dict_path', c.c_char_p), ('model_path', c.c_char_p), ('user_dir', c.c_char_p),
                    ('custom_words_path', c.c_char_p), ('english_words_path', c.c_char_p), ('gloss_path', c.c_char_p),
                    ('scheme', c.c_int32), ('fuzzy_mask', c.c_uint32), ('full_pinyin_preedit', c.c_int32),
                    ('freq_enabled', c.c_int32), ('english_enabled', c.c_int32)]
    class GcKeyEvent(c.Structure):
        _fields_ = [('kind', c.c_int32), ('arg', c.c_int64), ('time_ms', c.c_int64),
                    ('text', c.c_char_p), ('app', c.c_char_p), ('field', c.c_char_p)]
    class GcSnapshot(c.Structure):
        _fields_ = [('commit', c.c_char_p), ('marked', c.c_char_p), ('preedit', c.c_char_p),
                    ('preedit_caret', c.c_int64), ('typed_prefix_len', c.c_int64), ('consumed', c.c_int32),
                    ('composing', c.c_int32), ('english', c.c_int32), ('toast', c.c_int32), ('beep', c.c_int32),
                    ('status', c.c_char_p), ('candidates', c.c_void_p), ('count', c.c_size_t),
                    ('selected', c.c_size_t), ('page', c.c_size_t), ('page_count', c.c_size_t), ('total', c.c_size_t)]
    lib.gc_normal_session_create.argtypes = [c.POINTER(GcNormalConfig), c.POINTER(c.c_void_p), c.c_char_p, c.c_size_t]
    lib.gc_normal_session_create.restype = c.c_int
    lib.gc_normal_handle.argtypes = [c.c_void_p, c.POINTER(GcKeyEvent), c.POINTER(c.POINTER(GcSnapshot))]
    lib.gc_normal_handle.restype = c.c_int
    lib.gc_snapshot_free.argtypes = [c.POINTER(GcSnapshot)]
    lib.gc_normal_session_destroy.argtypes = [c.c_void_p]
    data = app / 'Contents/Resources/EngineData'
    cfg = GcNormalConfig(str(data / 'sc.dict').encode(), str(data / 'zh_CN.lm').encode(), None, None, None, None,
                         0, 0, 1, 0, 0)  # 小鹤；英文候选关闭（缺省降级包同样可测）
    handle = c.c_void_p()
    err = c.create_string_buffer(256)
    assert lib.gc_normal_session_create(c.byref(cfg), c.byref(handle), err, 256) == 0, err.value.decode()
    commit_text = None
    try:
        for i, key in enumerate('nihc'):
            ev = GcKeyEvent(0, 0, i, key.encode(), b'smoke.app', b'f')
            snap = c.POINTER(GcSnapshot)()
            assert lib.gc_normal_handle(handle, c.byref(ev), c.byref(snap)) == 0
            lib.gc_snapshot_free(snap)
        ev = GcKeyEvent(1, 0, 99, None, b'smoke.app', b'f')  # GC_EV_SPACE
        snap = c.POINTER(GcSnapshot)()
        assert lib.gc_normal_handle(handle, c.byref(ev), c.byref(snap)) == 0
        commit_text = snap.contents.commit.decode()
        lib.gc_snapshot_free(snap)
    finally:
        lib.gc_normal_session_destroy(handle)
    assert commit_text == '你好', f'包内核心上屏异常：{commit_text!r}'
    return 'passed_normal_xiaohe_from_package_abi_v2'

if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--input-app', type=Path, default=ROOT / 'dist/Gogaku.app')
    parser.add_argument('--settings-app', type=Path, default=ROOT / 'dist/Gogaku Settings.app')
    parser.add_argument('--report', type=Path, default=ROOT / 'docs/validation/bundle-smoke.json')
    args = parser.parse_args()
    report = {'checkedAt': datetime.now(timezone.utc).isoformat(), 'apps': [inspect(args.input_app), inspect(args.settings_app)],
              'menuIcon': menu_icon(args.input_app), 'engine': engine_smoke(args.input_app), 'normalCore': normal_core_smoke(args.input_app),
              'dataAndLicenses': data_and_license_smoke(args.input_app),
              'settingsAutoPinyin': auto_pinyin_smoke(args.settings_app), **spelling_smoke(args.input_app),
              'hostAcceptance': 'not_tested', 'qualityAcceptance': 'not_tested', 'performanceAcceptance': 'not_tested'}
    args.report.parent.mkdir(parents=True, exist_ok=True)
    args.report.write_text(json.dumps(report, ensure_ascii=False, indent=2) + '\n')
    print(json.dumps(report, ensure_ascii=False, indent=2))
