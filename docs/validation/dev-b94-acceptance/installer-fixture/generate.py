#!/usr/bin/env python3
"""Build isolated installer fixtures; never execute payloads or connect to Windows.
All generated files, compiler scratch, and Wine state stay below this directory.
"""
from __future__ import annotations

import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import struct
import subprocess
import sys

sys.dont_write_bytecode = True
BASE = Path(__file__).resolve().parent
ROOT = BASE.parents[2]
TEMPLATE = ROOT / 'windows/packaging/gogaku.iss.in'
ICON = ROOT / 'windows/assets/Gogaku.ico'
APP_ID = '{B74D13D2-0952-4B54-B124-671170C7A294}'
CLSID = '{B74D13D2-0952-4B54-B124-671170C7A295}'
CHANNEL = 'acceptance-b94'
RUN_VALUE = 'GogakuAcceptanceB94Agent'
MUTEX = 'GogakuAcceptanceB94Settings'
INSTALL_DIR = 'GogakuAcceptanceB94'
APP_NAME = 'Gogaku Acceptance B94'
EXPECTED_ROOT = r'%ProgramW6432%\GogakuAcceptanceB94'
WINE = ROOT / '.build/win-tools/wine/Wine Stable.app/Contents/Resources/wine/bin/wine'
ISCC = ROOT / '.build/win-tools/inno/ISCC.exe'
VARIANTS = [('A', 1, None), ('B-success', 2, None),
            ('B-fail-x64', 2, 'x64'), ('B-fail-x86', 2, 'x86')]


def digest(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def write(path: Path, text: str, encoding='utf-8'):
    path.resolve().relative_to(BASE)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text, encoding=encoding)


def json_file(path: Path, value):
    write(path, json.dumps(value, ensure_ascii=False, indent=2) + '\n')


def winpath(path: Path) -> str:
    return 'Z:' + str(path.resolve()).replace('/', '\\')


def invoke(command, name, env):
    with (BASE / 'logs' / name).open('w') as log:
        result = subprocess.run([str(arg) for arg in command], cwd=BASE,
                                env=env, stdout=log, stderr=subprocess.STDOUT)
    if result.returncode:
        raise RuntimeError(f'{name}: exit {result.returncode}; inspect {BASE / "logs" / name}')


def inspect_pe(path: Path, arch: str, dll: bool, env):
    data = path.read_bytes()
    if data[:2] != b'MZ':
        raise RuntimeError(f'Not PE: {path}')
    offset, = struct.unpack_from('<I', data, 0x3c)
    machine, = struct.unpack_from('<H', data, offset + 4)
    characteristics, = struct.unpack_from('<H', data, offset + 22)
    if data[offset:offset+4] != b'PE\0\0' or machine != {'x64': 0x8664, 'x86': 0x14c}[arch]:
        raise RuntimeError(f'Unexpected architecture: {path}')
    if bool(characteristics & 0x2000) != dll:
        raise RuntimeError(f'Unexpected DLL flag: {path}')
    prefix = 'x86_64' if arch == 'x64' else 'i686'
    result = subprocess.run([f'{prefix}-w64-mingw32-objdump', '-p', str(path)],
                            env=env, cwd=BASE, text=True, capture_output=True, check=True)
    write(BASE / 'logs' / f'{arch}-{path.name}.objdump.txt', result.stdout)
    imports = sorted(set(re.findall(r'DLL Name:\s+(\S+)', result.stdout)))
    allowed = {'kernel32.dll', 'advapi32.dll', 'msvcrt.dll', 'ucrtbase.dll', 'user32.dll'}
    if any(item.lower() not in allowed and not item.lower().startswith('api-ms-win-crt-')
           for item in imports):
        raise RuntimeError(f'Unexpected dependency: {imports}')
    exports = []
    if dll:
        table = result.stdout.split('[Ordinal/Name Pointer] Table', 1)[1]
        exports = re.findall(r'^\s*\[\s*\d+\]\s+(?:\+base\[\s*\d+\]\s+[0-9a-fA-F]+\s+)?(\S+)\s*$', table, re.M)
        if sorted(exports) != ['DllRegisterServer', 'DllUnregisterServer']:
            raise RuntimeError(f'Decorated or unexpected exports: {exports}')
    return {'arch': arch, 'dll': dll, 'sha256': digest(path), 'bytes': path.stat().st_size,
            'imports': imports, 'exports': exports}


def event(arch, operation, payload, hr='0x00000000', injected=False):
    return {'arch': arch, 'operation': operation, 'payload': payload,
            'hr': hr, 'injected': injected}


def vm_plan(packages):
    a = EXPECTED_ROOT + r'\versions\1.0.0-b1-acceptance-b94'
    b = EXPECTED_ROOT + r'\versions\1.0.0-b2-acceptance-b94'
    common = [
        'Wait for each process to terminate; read its ExitCode; record the full Inno /LOG output.',
        'After each step compare both registry views of dev/stable CLSIDs, channel pointers, Run values and uninstall records against the read-only baseline.',
        'User data directory names, file sets and SHA-256 values must equal baseline; do not launch any production Gogaku process.',
        'Read fixture-register.log from the install root and assert ordered new event slices, including architecture, operation, HRESULT, injected flag and full module path.',
        'Verify installed fixture files using the selected payload build-identity.json artifacts; fixture logs and installer bookkeeping are not payload artifacts.',
    ]
    def package_step(name):
        return {'package': name, 'file': packages[name]['path'],
                'sha256': packages[name]['sha256'],
                'arguments': ['/SP-', '/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART',
                              '/TASKS=""', '/LOG="<absolute-unique-step-log>"'],
                'override_dir': False}
    return {
        'platform': 'Windows 11 x64, elevated administrator; runtime NOT executed by this generator',
        'root_resolution': 'Expand %ProgramW6432% on the target. Never infer a user-selected production install root.',
        'preflight': [
            'Refuse if either isolated CLSID registry view, isolated channel key, fixture AppId uninstall record, install directory, or isolated Run value already exists in any loaded user hive. Do not overwrite unknown state.',
            'Read-only baseline: both production dev/stable COM and TSF registrations, pointers, uninstall keys, loaded-hive Run values and user-data file sets/hashes.',
            'Keep startmenu/autostartagent tasks unselected and do not launch settings. The EXE stubs intentionally do not implement --set-autostart.',
            'Create only an external scratch sentinel under %ProgramData%\\GogakuAcceptanceB94; retain it through uninstall as a control for data preservation.',
        ],
        'common_assertions': common,
        'sequence': [
            dict(package_step('A'), expect_exit=0, active_root=a, previous_root='',
                 assertions=['Both isolated InprocServer32 values equal A/bin/<arch>/GogakuTsf.dll; ThreadingModel=Apartment.',
                             'HKLM64 channel ActiveRoot=A, PreviousRoot exists as empty string; isolated uninstall record and unins000.exe exist.',
                             'No isolated Run value appears automatically. Snapshot A files and uninstall bookkeeping.',
                             'After assertion, seed only the isolated Run value in the operator loaded user hive with the exactly quoted A agent path; remember the SID.'],
                 expected_events=[event('x64', 'register', 'A'), event('x86', 'register', 'A')]),
            dict(package_step('B-fail-x64'), expect_exit='nonzero', active_root=a, previous_root='',
                 assertions=['First B/x64 register reports E_FAIL after its isolated InprocServer32 write.',
                             'No B/x86 register event; template still invokes B/x86 unregister followed by B/x64 unregister.',
                             'A x64/x86 restored successfully; pointers and seeded Run value exactly equal pre-attempt state.',
                             'All B payload files removed by rollback; empty directories may remain. A hashes and uninstall usability preserved.'],
                 expected_events=[event('x64', 'register', 'B', '0x80004005', True),
                                  event('x86', 'unregister', 'B'), event('x64', 'unregister', 'B'),
                                  event('x64', 'register', 'A'), event('x86', 'register', 'A')]),
            dict(package_step('B-fail-x86'), expect_exit='nonzero', active_root=a, previous_root='',
                 assertions=['B/x64 registration succeeds, B/x86 reports E_FAIL after writing its registration.',
                             'Both B registrations cleaned, both A registrations restored, pointers and seeded Run exactly preserved.',
                             'All B payload files removed by rollback; A artifact hashes unchanged.'],
                 expected_events=[event('x64', 'register', 'B'),
                                  event('x86', 'register', 'B', '0x80004005', True),
                                  event('x86', 'unregister', 'B'), event('x64', 'unregister', 'B'),
                                  event('x64', 'register', 'A'), event('x86', 'register', 'A')]),
            dict(package_step('B-success'), expect_exit=0, active_root=b, previous_root=a,
                 assertions=['Both isolated COM views point to B; ActiveRoot=B and PreviousRoot=A.',
                             'Seeded loaded-user Run value migrated to exactly quoted B agent path; initially absent Run values in other hives remain absent.',
                             'No failure markers in B-success; B artifact hashes verified; A files retained.'],
                 expected_events=[event('x64', 'register', 'B'), event('x86', 'register', 'B')]),
            {'action': 'uninstall', 'file': EXPECTED_ROOT + r'\unins000.exe',
             'arguments': ['/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART', '/LOG="<absolute-uninstall-log>"'],
             'expect_exit': 0,
             'expected_events': [event('x64', 'unregister', 'B'), event('x86', 'unregister', 'B')],
             'assertions': ['Both isolated CLSID keys absent; channel ActiveRoot/PreviousRoot absent (empty channel key allowed).',
                            'Seeded owned Run value absent; fixture uninstall record and all A/B installed payload files removed.',
                            'Scratch sentinel retained; production snapshots unchanged. Copy fixture-register.log out before optional cleanup of the isolated residual log/root.']},
        ],
        'limitations': ['These packages cover real Inno/regsvr32 rollback and successful uninstall with a controlled DLL, not TSF/CTF registration or keyboard input.',
                        'Unregister-failure and ACL/pointer-write-failure injections are not included in these four variants.',
                        'Failure occurs before pointer/Run migration; these two cases assert their preservation, not rollback after a partially completed migration.',
                        'Do not run B-success before failure cases: all B variants intentionally share the same installed version root.'],
    }


def main():
    for name in ('bin/x64', 'bin/x86', 'packages', 'logs', 'tmp', 'cache', 'config', 'wine-prefix'):
        (BASE / name).mkdir(parents=True, exist_ok=True)
    env = dict(os.environ, TMPDIR=str(BASE / 'tmp'), TMP=str(BASE / 'tmp'), TEMP=str(BASE / 'tmp'),
               XDG_CACHE_HOME=str(BASE / 'cache'), XDG_CONFIG_HOME=str(BASE / 'config'),
               WINEPREFIX=str(BASE / 'wine-prefix'), WINEARCH='win64', WINEDEBUG='-all',
               WINEDLLOVERRIDES='winemenubuilder.exe=d;mscoree,mshtml=d', MVK_CONFIG_LOG_LEVEL='0')
    env['PATH'] = str(WINE.parent) + os.pathsep + env.get('PATH', '')
    if not WINE.is_file() or not ISCC.is_file():
        raise RuntimeError('Existing Wine/Inno compiler missing')
    # No use of the production wrapper: its prefix/cache/tmp live outside BASE.
    template_bytes = TEMPLATE.read_bytes()
    template = template_bytes.decode('utf-8')
    checks = {}
    for arch, prefix in [('x64', 'x86_64'), ('x86', 'i686')]:
        compiler = shutil.which(f'{prefix}-w64-mingw32-gcc')
        if not compiler:
            raise RuntimeError(f'Missing {prefix} compiler')
        dll = BASE / 'bin' / arch / 'GogakuTsf.dll'
        exports_file = BASE / 'register.def'
        if arch == 'x86':
            exports_file = BASE / 'scripts/register-x86.def'
            write(exports_file, re.sub(r'^    (\w+)$', r'    \1=\1@0',
                                      (BASE / 'register.def').read_text(), flags=re.M))
        invoke([compiler, '-std=c11', '-O2', '-Wall', '-Wextra', '-Werror', '-shared',
                '-static-libgcc', BASE / 'register.c', exports_file,
                '-Wl,--kill-at', '-Wl,--disable-stdcall-fixup', '-Wl,--no-insert-timestamp', '-ladvapi32', '-o', dll],
               f'compile-{arch}.log', env)
        checks[arch] = inspect_pe(dll, arch, True, env)
    stub = BASE / 'bin/x64/GogakuAgent.exe'
    invoke(['x86_64-w64-mingw32-gcc', '-std=c11', '-O2', '-Wall', '-Wextra', '-Werror',
            '-mwindows', '-static-libgcc', '-Wl,--no-insert-timestamp', BASE / 'noop.c', '-o', stub],
           'compile-noop.log', env)
    shutil.copyfile(stub, BASE / 'bin/x64/GogakuSettings.exe')
    checks['noop'] = inspect_pe(stub, 'x64', False, env)
    packages = {}
    for variant, build, failure in VARIANTS:
        stage = BASE / 'payloads' / variant
        if stage.exists():
            shutil.rmtree(stage)
        for arch in ('x64', 'x86'):
            dest = stage / 'bin' / arch
            dest.mkdir(parents=True)
            for source in (BASE / 'bin' / arch).iterdir():
                shutil.copyfile(source, dest / source.name)
        for folder in ('data', 'resources', 'licenses'):
            write(stage / folder / 'FIXTURE.txt', f'ISOLATED INSTALLER FIXTURE ONLY: {variant}; {folder}\n')
        if failure:
            write(stage / 'data' / f'fail-register-{failure}.flag', 'return E_FAIL after writing isolated registration\n')
        identity = {'fixture': True, 'fullVersion': '1.0.0', 'buildNumber': build,
                    'channel': CHANNEL, 'variant': variant, 'failureArchitecture': failure,
                    'productionTemplateSha256': hashlib.sha256(template_bytes).hexdigest(),
                    'artifacts': {str(p.relative_to(stage)).replace(os.sep, '/'): {
                        'sha256': digest(p), 'bytes': p.stat().st_size}
                        for p in sorted(stage.rglob('*')) if p.is_file()}}
        json_file(stage / 'build-identity.json', identity)
        replacements = {
            '@APP_NAME@': APP_NAME, '@VERSION@': '1.0.0', '@BUILD@': str(build),
            '@CHANNEL@': CHANNEL, '@APP_ID@': '{' + APP_ID, '@TSF_CLSID@': CLSID,
            '@INSTALL_DIR@': INSTALL_DIR, '@AGENT_RUN_VALUE@': RUN_VALUE,
            '@APP_MUTEX@': MUTEX, '@VERSION_QUAD@': f'1.0.0.{build}',
            '@OUTPUT_DIR@': winpath(BASE / 'packages'), '@OUTPUT_BASE@': variant,
            '@STAGE_DIR@': winpath(stage), '@ICON_FILE@': winpath(ICON),
            '@REPO@': 'gogaku/gogaku-releases',
        }
        if set(re.findall(r'@[A-Z_]+@', template)) != set(replacements):
            raise RuntimeError('Template placeholder contract changed')
        rendered = template
        for token, value in replacements.items():
            if any(c in value for c in ('"', '\r', '\n')):
                raise RuntimeError(f'Unsafe template value: {token}')
            rendered = rendered.replace(token, value)
        code_expected = template.split('[Code]\n', 1)[1].replace('@AGENT_RUN_VALUE@', RUN_VALUE)
        code_actual = rendered.split('[Code]\n', 1)[1]
        if code_actual != code_expected or re.search(r'@[A-Z_]+@', rendered):
            raise RuntimeError('Code changed or unresolved template placeholder')
        iss = BASE / 'scripts' / f'{variant}.iss'
        write(iss, rendered, encoding='utf-8-sig')
        setup = BASE / 'packages' / f'{variant}.exe'
        setup.unlink(missing_ok=True)
        print(f'Compiling {variant} with existing Wine/ISCC', flush=True)
        invoke([WINE, ISCC, winpath(iss)], f'iscc-{variant}.log', env)
        if not setup.is_file() or setup.stat().st_size < 10000 or setup.read_bytes()[:2] != b'MZ':
            raise RuntimeError(f'ISCC output missing/invalid: {setup}')
        packages[variant] = {
            'path': str(setup), 'relativePath': str(setup.relative_to(BASE)),
            'sha256': digest(setup), 'bytes': setup.stat().st_size,
            'version': '1.0.0', 'build': build, 'channel': CHANNEL,
            'expectedVersionRoot': EXPECTED_ROOT + f'\\versions\\1.0.0-b{build}-{CHANNEL}',
            'expectedInstallExit': 0 if failure is None else 'nonzero',
            'failureMarker': None if failure is None else f'data/fail-register-{failure}.flag',
            'iss': str(iss), 'issSha256': digest(iss),
            'payload': str(stage), 'identitySha256': digest(stage / 'build-identity.json'),
            'codeTransactionUnchanged': True,
            'codeSha256': hashlib.sha256(code_actual.encode()).hexdigest(),
        }
    if TEMPLATE.read_bytes() != template_bytes:
        raise RuntimeError('Production template changed during build')
    report = {
        'schema': 1, 'fixtureOnly': True, 'executedPayloadOrInstaller': False,
        'template': str(TEMPLATE), 'templateSha256': hashlib.sha256(template_bytes).hexdigest(),
        'identity': {'appId': APP_ID, 'channel': CHANNEL, 'tsfClsid': CLSID,
                     'runValue': RUN_VALUE, 'mutex': MUTEX,
                     'defaultDirName': r'{autopf}\GogakuAcceptanceB94',
                     'channelKey64': r'HKLM\Software\Gogaku\acceptance-b94',
                     'clsidKeyBothViews': 'HKLM\\Software\\Classes\\CLSID\\' + CLSID,
                     'uninstallKey64': 'HKLM\\Software\\Microsoft\\Windows\\CurrentVersion\\Uninstall\\' + APP_ID + '_is1'},
        'staticChecks': checks, 'packages': packages,
        'tools': {'wine': str(WINE), 'iscc': str(ISCC), 'isccSha256': digest(ISCC)},
        'runtimeLog': EXPECTED_ROOT + r'\fixture-register.log',
        'vmExecution': vm_plan(packages),
    }
    json_file(BASE / 'packages.json', report)
    print(f'Built and statically checked {len(packages)} packages: {BASE / "packages.json"}', flush=True)


if __name__ == '__main__':
    main()
