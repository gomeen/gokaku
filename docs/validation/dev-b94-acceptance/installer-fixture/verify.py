#!/usr/bin/env python3
"""只读检查安装夹具；唯一输出为本目录 verification.json，不执行任何 PE。"""
import hashlib
import json
from pathlib import Path
import re
import struct
import subprocess

BASE = Path(__file__).resolve().parent
ROOT = BASE.parents[2]


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def pe(path, arch, dll):
    data = path.read_bytes()
    assert data[:2] == b'MZ', path
    offset, = struct.unpack_from('<I', data, 0x3c)
    assert data[offset:offset + 4] == b'PE\0\0', path
    machine, = struct.unpack_from('<H', data, offset + 4)
    flags, = struct.unpack_from('<H', data, offset + 22)
    assert machine == {'x64': 0x8664, 'x86': 0x14c}[arch], path
    assert bool(flags & 0x2000) == dll, path
    prefix = 'x86_64' if arch == 'x64' else 'i686'
    output = subprocess.check_output([f'{prefix}-w64-mingw32-objdump', '-p', str(path)], text=True)
    dependencies = re.findall(r'DLL Name:\s+(\S+)', output)
    assert all(item.lower() in {'kernel32.dll', 'advapi32.dll', 'msvcrt.dll', 'ucrtbase.dll',
                                'user32.dll', 'comctl32.dll', 'oleaut32.dll'}
               or item.lower().startswith('api-ms-win-crt-') for item in dependencies), dependencies
    if dll:
        table = output.split('[Ordinal/Name Pointer] Table', 1)[1].split('\n\n', 1)[0]
        exports = [line.split()[-1] for line in table.splitlines() if re.match(r'^\s*\[\s*\d+\]', line)]
        assert sorted(exports) == ['DllRegisterServer', 'DllUnregisterServer'], exports
    return dependencies


def main():
    manifest = json.loads((BASE / 'packages.json').read_text())
    assert not manifest['executedPayloadOrInstaller']
    identity = manifest['identity']
    assert identity['appId'] == '{B74D13D2-0952-4B54-B124-671170C7A294}'
    assert identity['tsfClsid'] == '{B74D13D2-0952-4B54-B124-671170C7A295}'
    assert identity['channel'] == 'acceptance-b94'
    assert identity['runValue'] == 'GogakuAcceptanceB94Agent'
    assert identity['mutex'] == 'GogakuAcceptanceB94Settings'
    assert identity['defaultDirName'] == r'{autopf}\GogakuAcceptanceB94'
    template = ROOT / 'windows/packaging/gogaku.iss.in'
    assert sha(template) == manifest['templateSha256']
    code = template.read_text().split('[Code]\n', 1)[1].replace('@AGENT_RUN_VALUE@', identity['runValue'])
    assert set(manifest['packages']) == {'A', 'B-success', 'B-fail-x64', 'B-fail-x86'}
    checked = {}
    for name, entry in manifest['packages'].items():
        setup = Path(entry['path'])
        setup.resolve().relative_to(BASE)
        assert sha(setup) == entry['sha256'] and setup.stat().st_size == entry['bytes']
        # Inno Setup's loader is x86; it installs both fixture architectures.
        pe(setup, 'x86', False)
        iss = Path(entry['iss'])
        assert sha(iss) == entry['issSha256']
        rendered = iss.read_text(encoding='utf-8-sig')
        assert rendered.split('[Code]\n', 1)[1] == code
        assert hashlib.sha256(code.encode()).hexdigest() == entry['codeSha256']
        assert not re.search(r'@[A-Z_]+@', rendered)
        for line in ['#define AppId "{' + identity['appId'] + '"',
                     '#define TsfClsid "' + identity['tsfClsid'] + '"',
                     '#define AppChannel "acceptance-b94"',
                     '#define AppVersion "1.0.0"',
                     '#define AppBuild "' + str(entry['build']) + '"',
                     'DefaultDirName={autopf}\\GogakuAcceptanceB94',
                     'AppMutex=GogakuAcceptanceB94Settings']:
            assert line in rendered, line
        stage = Path(entry['payload'])
        assert sha(stage / 'build-identity.json') == entry['identitySha256']
        payload = json.loads((stage / 'build-identity.json').read_text())
        assert payload['variant'] == name and payload['buildNumber'] == (1 if name == 'A' else 2)
        artifacts = payload['artifacts']
        actual = {str(p.relative_to(stage)) for p in stage.rglob('*') if p.is_file()}
        assert actual == set(artifacts) | {'build-identity.json'}
        compile_log = (BASE / 'logs' / f'iscc-{name}.log').read_text()
        compressed = re.findall(r'Compressing: (Z:[^\r\n]+)', compile_log)
        expected_inputs = {'Z:' + str((stage / relative).resolve()).replace('/', '\\')
                           for relative in actual}
        assert set(compressed) == expected_inputs, name
        assert 'Successful compile' in compile_log
        for relative, artifact in artifacts.items():
            path = stage / relative
            assert sha(path) == artifact['sha256'] and path.stat().st_size == artifact['bytes']
        markers = {str(p.relative_to(stage)) for p in (stage / 'data').glob('*.flag')}
        assert markers == ({entry['failureMarker']} if entry['failureMarker'] else set())
        for arch in ('x64', 'x86'):
            dll = stage / 'bin' / arch / 'GogakuTsf.dll'
            assert sha(dll) == sha(BASE / 'bin' / arch / 'GogakuTsf.dll')
            pe(dll, arch, True)
        for exe in ('GogakuAgent.exe', 'GogakuSettings.exe'):
            pe(stage / 'bin/x64' / exe, 'x64', False)
        checked[name] = {'sha256': sha(setup), 'bytes': setup.stat().st_size,
                         'payloadFiles': len(actual), 'codeTransactionUnchanged': True,
                         'expectedFailureMarker': entry['failureMarker']}
    for name in ('compile-x64.log', 'compile-x86.log', 'compile-noop.log'):
        assert not (BASE / 'logs' / name).read_text().strip(), name
    output = {'staticVerificationPassed': True, 'runtimeExecuted': False,
              'templateSha256': sha(template), 'packages': checked}
    (BASE / 'verification.json').write_text(json.dumps(output, indent=2) + '\n')
    print(json.dumps(output, indent=2))


if __name__ == '__main__':
    main()
