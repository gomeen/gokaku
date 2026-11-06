"""构建输入、产物与验证报告的窄交付合同；收据是本地构建证据，不替代签名。"""
from __future__ import annotations

import hashlib
import json
from pathlib import Path
import plistlib
import re
import subprocess

ROOT = Path(__file__).resolve().parent.parent
SOURCE_PATHS = ('Sources', 'native', 'resources', 'assets', 'packaging', 'scripts',
                'Package.swift', 'version.json', 'docs/third-party.md')


class DeliveryError(ValueError):
    pass


def sha256(path):
    h = hashlib.sha256()
    with Path(path).open('rb') as stream:
        for chunk in iter(lambda: stream.read(1 << 20), b''):
            h.update(chunk)
    return h.hexdigest()


def read_json(path):
    try:
        return json.loads(Path(path).read_text(encoding='utf-8'))
    except (OSError, ValueError) as error:
        raise DeliveryError(f'无法读取交付证据 {path}：{error}') from error


def write_json(path, value):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(path.name + '.tmp')
    temporary.write_text(json.dumps(value, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
    temporary.replace(path)


def file_manifest(folder):
    folder = Path(folder)
    return {str(p.relative_to(folder)): {'sha256': sha256(p), 'bytes': p.stat().st_size}
            for p in sorted(folder.rglob('*')) if p.is_file()
            and '__pycache__' not in p.parts and p.name != '.DS_Store'}


def source_fingerprint(root=ROOT):
    root = Path(root)
    entries = {}
    for relative in SOURCE_PATHS:
        path = root / relative
        paths = sorted(path.rglob('*')) if path.is_dir() else [path]
        for item in paths:
            if item.is_file() and '__pycache__' not in item.parts and item.name != '.DS_Store':
                entries[str(item.relative_to(root))] = sha256(item)
    return hashlib.sha256(json.dumps(entries, sort_keys=True).encode()).hexdigest()


def current_meta(root=ROOT):
    value = read_json(Path(root) / 'version.json')
    if (not isinstance(value, dict) or set(value) != {'version', 'buildNumber'}
            or not isinstance(value['version'], str)
            or not re.fullmatch(r'(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(?:-(?:dev|rc)\.(?:0|[1-9][0-9]*))?', value['version'])
            or type(value['buildNumber']) is not int or not 1 <= value['buildNumber'] <= 65535):
        raise DeliveryError('非法 version.json；版本须为 dev.N／rc.N／定版，构建号为 1–65535')
    return value


def working_tree_dirty(root=ROOT):
    root = Path(root)
    tracked = subprocess.check_output(
        ['git', '-C', str(root), 'status', '--porcelain', '--untracked-files=no'], text=True)
    # 忽略未跟踪的验证报告，但未提交的源码/资源不能冒充干净发布。
    source_files = subprocess.check_output(
        ['git', '-C', str(root), 'ls-files', '--others', '--exclude-standard', '--', *SOURCE_PATHS],
        text=True)
    return bool(tracked.strip() or source_files.strip())


def git_identity(root=ROOT):
    try:
        def git(*args):
            return subprocess.check_output(['git', '-C', str(root), *args], text=True).strip()
        return {'commit': git('rev-parse', 'HEAD'),
                'dirty': working_tree_dirty(root)}
    except (OSError, subprocess.CalledProcessError) as error:
        raise DeliveryError(f'无法读取 Git 身份：{error}') from error


def check_identity(value, channel, *, root=ROOT, meta=None, source=None):
    meta = meta or current_meta(root)
    if value.get('fullVersion') != meta['version'] or value.get('buildNumber') != meta['buildNumber']:
        raise DeliveryError('产物版本／构建号与 version.json 不符；请重新构建')
    if value.get('channel') != channel:
        raise DeliveryError('产物通道不符；请重新构建同通道产物')
    if value.get('sourceSha256') != (source or source_fingerprint(root)):
        raise DeliveryError('源码／资源已变化或缺少源码身份；请重新构建')
    git = value.get('git', {})
    if not isinstance(git, dict) or not git.get('commit') or type(git.get('dirty')) is not bool:
        raise DeliveryError('缺少 Git 构建身份')
    if '-dev.' not in meta['version'] and git['dirty']:
        raise DeliveryError('rc／定版不接受 dirty 构建')
    if channel == 'stable' and '-' in meta['version']:
        raise DeliveryError('stable 通道只接受正式版本')
    return value


def validate_compile_receipt(path, folder, channel, arch, *, root=ROOT, meta=None, source=None):
    receipt = read_json(path)
    check_identity(receipt, channel, root=root, meta=meta, source=source)
    if receipt.get('schema') != 1 or receipt.get('arch') != arch or receipt.get('configuration') != 'release':
        raise DeliveryError(f'{path} 编译配置／架构不符')
    artifacts = receipt.get('artifacts', {})
    required = {'GogakuTsf.dll'}
    if arch == 'x64':
        required |= {'GogakuAgent.exe', 'GogakuSettings.exe', 'libgogaku_core.dll'}
    if set(artifacts) != required:
        raise DeliveryError(f'{path} 编译收据缺少必需组件')
    for name, info in artifacts.items():
        item = Path(folder) / name
        if not item.is_file() or info != {'sha256': sha256(item), 'bytes': item.stat().st_size}:
            raise DeliveryError(f'编译产物已变化：{item}；请重新编译')
    return receipt


def validate_macos_apps(dist, channel, *, root=ROOT):
    dist = Path(dist)
    suffix = '-dev' if channel == 'dev' else ''
    identity = read_json(dist / f'build-identity{suffix}.json')
    check_identity(identity, channel, root=root)
    if identity.get('configuration') != 'release' or identity.get('validationBuild') is not False:
        raise DeliveryError('对外 pkg 必须使用 Release、非 validation 的双 App')
    names = ['Gogaku Dev.app', 'Gogaku Settings Dev.app'] if channel == 'dev' else ['Gogaku.app', 'Gogaku Settings.app']
    identifiers = ['org.gogaku.inputmethod', 'org.gogaku.settings']
    if set(identity.get('apps', {})) != set(names):
        raise DeliveryError('双 App 身份清单／通道不符')
    for name, identifier in zip(names, identifiers):
        app = dist / name
        try:
            info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
        except (OSError, ValueError) as error:
            raise DeliveryError(f'无法读取 {app}：{error}') from error
        expected_id = identifier + ('.dev' if channel == 'dev' else '')
        if (info.get('CFBundleIdentifier') != expected_id
                or info.get('CFBundleVersion') != str(identity['buildNumber'])
                or info.get('CFBundleShortVersionString') != identity['fullVersion'].split('-', 1)[0]):
            raise DeliveryError(f'{name} 版本／构建号／身份不符；请重新构建')
        entry = identity['apps'][name]
        if entry.get('files') != file_manifest(app):
            raise DeliveryError(f'{name} 文件与构建收据不符；请重新构建')
        embedded = read_json(app / 'Contents/Resources/build-identity.json')
        if embedded != entry.get('identity'):
            raise DeliveryError(f'{name} 包内身份变化')
        check_identity(embedded, channel, root=root, source=identity['sourceSha256'])
    return identity


def package_receipt_path(package):
    return Path(str(package) + '.receipt.json')


def write_package_receipt(package, platform, channel, identity, identity_path, license_files, *, root=ROOT):
    check_identity(identity, channel, root=root)
    if not license_files:
        raise DeliveryError('安装包缺少实际许可材料证据')
    package = Path(package)
    receipt = {key: identity[key] for key in ('fullVersion', 'buildNumber', 'sourceSha256', 'git')}
    receipt.update(schema=1, kind='installer', platform=platform, arch='x86_64', channel=channel,
                   configuration='release', validationBuild=False,
                   inputIdentitySha256=sha256(identity_path), licenseFiles=sorted(license_files),
                   artifact={'name': package.name, 'sha256': sha256(package), 'bytes': package.stat().st_size})
    path = package_receipt_path(package)
    write_json(path, receipt)
    return path


def validate_package(package, platform, channel, *, root=ROOT):
    package = Path(package)
    receipt = read_json(package_receipt_path(package))
    check_identity(receipt, channel, root=root)
    if (receipt.get('schema') != 1 or receipt.get('kind') != 'installer'
            or receipt.get('platform') != platform or receipt.get('arch') != 'x86_64'
            or receipt.get('configuration') != 'release' or receipt.get('validationBuild') is not False
            or not receipt.get('licenseFiles') or not receipt.get('inputIdentitySha256')):
        raise DeliveryError('安装包收据缺少平台／配置／许可／构建证据')
    if (not package.is_file() or package.stat().st_size == 0
            or receipt.get('artifact') != {'name': package.name, 'sha256': sha256(package),
                                            'bytes': package.stat().st_size}):
        raise DeliveryError(f'安装包与构建收据不符：{package}')
    return receipt


def validate_reports(paths, packages, channel, *, root=ROOT):
    meta = current_meta(root)
    required_profiles = {'fast'} if '-dev.' in meta['version'] else {'fast', 'release', 'host'}
    expected = {p['platform']: p['artifact'] for p in packages}
    profiles = set()
    for path in paths:
        report = read_json(path)
        if (report.get('version') != meta or report.get('channel') != channel
                or report.get('sourceSha256') != source_fingerprint(root)
                or report.get('gate', {}).get('passed') is not True
                or not report.get('checks')
                or any(c.get('status') != 'passed' for c in report['checks'] if c.get('required'))
                or (required_profiles != {'fast'} and report.get('quick'))):
            raise DeliveryError(f'验证报告缺失、未通过或指向其他源码／版本：{path}')
        if report.get('artifacts') != expected:
            raise DeliveryError(f'验证报告未绑定本轮双端安装包哈希：{path}')
        if required_profiles != {'fast'} and report.get('dirty'):
            raise DeliveryError('rc／定版验证报告必须来自干净工作区')
        profiles.add(report.get('profile'))
    if not required_profiles <= profiles:
        raise DeliveryError(f'缺少必需验证报告：{sorted(required_profiles - profiles)}')
