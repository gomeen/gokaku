#!/usr/bin/env python3
"""Prepare isolated Qingjian Q0 from pinned production artifacts, never fixtures.

All upstream source, data, Cargo cache, projects and results stay under /tmp.
Run: python3 probes/prepare-qingjian-input.py
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import struct
import subprocess
import sys
import tarfile
import urllib.request

ROOT = Path('/tmp/gogaku-ime-benchmark/qingjian')
REV = '379139671d191a5c9dc21972a54e15bc1edd9e17'
REPO = 'https://github.com/qingjian-team/qingjian'
RAW = f'https://raw.githubusercontent.com/qingjian-team/qingjian/{REV}/'
SOURCE_URL = f'https://codeload.github.com/qingjian-team/qingjian/tar.gz/{REV}'
SOURCE_SHA = 'd14f6b90081223b3e7d664dd135189539947155aee9640005a3fbbfa6ad3c8a3'
DATA_URL = REPO + '/releases/download/data-v8/qingjian-data.tar.gz'
DATA_SHA = 'c8aef81032b8cb2ca9f66e53a13f530b540c0ea5570ac5a9876dc71838868116'
HERE = Path(__file__).resolve().parent


def sha(path):
    digest = hashlib.sha256()
    with path.open('rb') as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b''):
            digest.update(chunk)
    return digest.hexdigest()


def fetch(url, path, expected=None):
    if path.exists() and (expected is None or sha(path) == expected):
        return
    path.parent.mkdir(parents=True, exist_ok=True)
    partial = path.with_suffix(path.suffix + '.part')
    print('Downloading ' + url, file=sys.stderr, flush=True)
    with urllib.request.urlopen(url, timeout=90) as source, partial.open('wb') as target:
        shutil.copyfileobj(source, target)
    if expected and sha(partial) != expected:
        raise RuntimeError('SHA-256 mismatch: ' + str(path))
    partial.replace(path)


def extract(path, destination):
    with tarfile.open(path, 'r:gz') as archive:
        # No symlink tricks or paths escaping the isolated root.
        archive.extractall(destination, filter='data')


def qj_metadata(path):
    with path.open('rb') as stream:
        header = stream.read(56)
        if header[:8] != b'QINGJIAN' or header[32:36] != b'META':
            raise RuntimeError('Unsupported .qj header: ' + str(path))
        offset, length = struct.unpack_from('<QQ', header, 40)
        stream.seek(offset)
        return stream.read(length).decode('utf-8')


def run(command, **kwargs):
    print('Running: ' + ' '.join(map(str, command)), file=sys.stderr, flush=True)
    return subprocess.run(command, check=True, **kwargs)


def smoke(command, evidence):
    process = subprocess.Popen(command, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                               stderr=subprocess.PIPE, text=True)
    transcript = []
    def request(value):
        process.stdin.write(json.dumps(value) + '\n')
        process.stdin.flush()
        response = json.loads(process.stdout.readline())
        transcript.append({'request': value, 'response': response})
        if value['op'] != 'quit':
            for field in ('ok', 'handled', 'preedit', 'raw_input', 'candidates', 'commit',
                          'composing', 'process_ns', 'collect_ns', 'total_ns'):
                assert field in response, (field, response)
            assert 0 <= response['process_ns'] + response['collect_ns'] <= response['total_ns']
            assert len(response['candidates']) <= 10
        return response
    try:
        ready = json.loads(process.stdout.readline())
        assert ready['ready'] and ready['config']['id'] == 'Q0'
        final_candidates = {}
        for keys in ('nihc', 'kdhv', 'woxlxtykyu'):
            assert request({'op': 'reset'})['raw_input'] == ''
            for key in keys:
                response = request({'op': 'key', 'key': ord(key)})
                assert response['ok'] and response['commit'] == ''
            assert response['raw_input'] == keys and response['composing']
            final_candidates[keys] = response['candidates']
            first = response['candidates'][0]
            peek = request({'op': 'peek'})
            assert peek['candidates'] == response['candidates'] and peek['commit'] == ''
            response = request({'op': 'select', 'index': 0})
            assert response['ok'] and response['commit'] == first
            assert not response['composing'] and response['raw_input'] == ''
            assert request({'op': 'peek'})['commit'] == ''
        # Force a real prefix selection, then restore it with Backspace.
        request({'op': 'reset'})
        for key in 'nihc':
            response = request({'op': 'key', 'key': ord(key)})
        prefix_index = response['candidates'].index('你')
        response = request({'op': 'select', 'index': prefix_index})
        assert response['commit'] == '' and response['held'] == '你'
        assert response['raw_input'] == 'hc' and response['composing']
        response = request({'op': 'key', 'key': 8})
        assert response['raw_input'] == 'nihc' and response['held'] == ''
        request({'op': 'select', 'index': prefix_index})
        response = request({'op': 'key', 'key': 32})
        assert response['commit'] == '你好' and not response['composing']
        request({'op': 'reset'})
        for key in 'nihc':
            response = request({'op': 'key', 'key': ord(key)})
        response = request({'op': 'key', 'key': 8})
        assert response['raw_input'] == 'nih'
        response = request({'op': 'key', 'key': 27})
        assert not response['composing'] and response['raw_input'] == ''
        assert request({'op': 'key', 'key': 32})['handled'] is False
        assert request({'op': 'select', 'index': 0})['ok'] is False
        assert request({'op': 'key', 'key': 999})['ok'] is False
        assert request({'op': 'bogus'})['ok'] is False
        # Reset must discard held text, and Return must preserve it in a raw commit.
        for ending in ('reset', 'escape', 'return'):
            request({'op': 'reset'})
            for key in 'nihc':
                response = request({'op': 'key', 'key': ord(key)})
            request({'op': 'select', 'index': response['candidates'].index('你')})
            operation = {'op': 'reset'} if ending == 'reset' else {'op': 'key', 'key': 27 if ending == 'escape' else 13}
            response = request(operation)
            assert response['raw_input'] == '' and response['held'] == '' and not response['composing']
            assert response['commit'] == ('你hc' if ending == 'return' else '')
        request({'op': 'quit'})
        process.wait(timeout=10)
        assert process.returncode == 0
        result = {'kind': 'correctness-smoke-only; no formal performance pass',
                  'ready': ready, 'known_candidates': final_candidates,
                  'transcript': transcript, 'stderr': process.stderr.read()}
        evidence.write_text(json.dumps(result, ensure_ascii=False, indent=2) + '\n')
        return result
    finally:
        if process.poll() is None:
            process.kill()
            process.wait()
        # Preserve even a failing smoke transcript for diagnosis.
        if not evidence.exists():
            evidence.write_text(json.dumps({'transcript': transcript}, ensure_ascii=False, indent=2) + '\n')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--skip-smoke', action='store_true')
    args = parser.parse_args()
    ROOT.mkdir(parents=True, exist_ok=True)
    # Examine exact-version licensing BEFORE downloading the source/data archives.
    license_paths = ['LICENSE', 'docs/design/landscape.md', 'tools/release/data.lock',
                     'assets/lexicon/README.md', 'assets/lexicon/05_english/README.md',
                     'assets/lexicon/00_meta/THUOCL_LICENSE.txt',
                     'assets/lexicon/05_english/sources/ESDB_Copyright.txt',
                     'assets/lexicon/05_english/sources/CSpell_LICENSE-MIT.txt',
                     'assets/lexicon/05_english/sources/typos_LICENSE-MIT.txt',
                     'assets/emoji/LICENSE-unicode.txt', 'tools/release/pack-model.sh']
    license_evidence = []
    for name in license_paths:
        path = ROOT / 'license-review' / name
        fetch(RAW + name, path)
        license_evidence.append({'source': RAW + name, 'local': str(path), 'sha256': sha(path)})
    landscape = (ROOT / 'license-review/docs/design/landscape.md').read_text()
    lock = (ROOT / 'license-review/tools/release/data.lock').read_text()
    assert 'GPL-3.0-or-later' in landscape and 'CC BY-SA 4.0' in landscape
    assert 'data-v8' in lock and DATA_SHA in lock
    fetch(SOURCE_URL, ROOT / 'source.tar.gz', SOURCE_SHA)
    source = ROOT / 'source'
    if not source.exists():
        extract(ROOT / 'source.tar.gz', ROOT)
        (ROOT / ('qingjian-' + REV)).rename(source)
    assert (source / 'tools/release/data.lock').read_text() == lock
    fetch(DATA_URL, ROOT / 'qingjian-data.tar.gz', DATA_SHA)
    if not (ROOT / 'data/generated/lm.qj').exists():
        extract(ROOT / 'qingjian-data.tar.gz', ROOT)
    # Inspect the exact deployed data before compiling anything. The archive also
    # contains an unused neural .qjm; record its hash but never load that model.
    data_records = []
    loaded = {'data/generated/dict.qj', 'data/generated/lm.qj',
              'data/generated/dicts/general.qj', 'data/generated/dicts/idioms.qj',
              'data/generated/english.tsv'}
    for path in sorted((ROOT / 'data').rglob('*')):
        if path.is_file():
            name = str(path.relative_to(ROOT))
            record = {'path': str(path), 'sha256': sha(path), 'bytes': path.stat().st_size,
                      'loaded': name in loaded, 'archive_source': DATA_URL}
            if path.suffix == '.qj':
                record['metadata_toml'] = qj_metadata(path)
            data_records.append(record)
    for name in ('emoji-zh.tsv', 'emoji-en.tsv', 'LICENSE-unicode.txt'):
        path = source / 'assets/emoji' / name
        data_records.append({'path': str(path), 'sha256': sha(path),
                             'source': RAW + 'assets/emoji/' + name,
                             'loaded': name.endswith('.tsv')})
    project = ROOT / 'worker'
    (project / 'src').mkdir(parents=True, exist_ok=True)
    template = HERE / 'qingjian-input-worker'
    (project / 'Cargo.toml').write_text((template / 'Cargo.toml').read_text().replace('@SOURCE@', str(source)))
    shutil.copyfile(template / 'src/main.rs', project / 'src/main.rs')
    if not (project / 'Cargo.lock').exists():
        shutil.copyfile(source / 'Cargo.lock', project / 'Cargo.lock')
    environment = dict(os.environ, CARGO_HOME=str(ROOT / 'cargo-home'),
                       CARGO_TARGET_DIR=str(ROOT / 'build'), CARGO_BUILD_JOBS='2')
    command = [str(ROOT / 'build/release/gogaku-qingjian-worker'), str(ROOT)]
    build = ['cargo', 'build', '--release', '--manifest-path', str(project / 'Cargo.toml')]
    manifest = {'id': 'Q0', 'engine': 'qingjian-core', 'version': REV, 'command': command,
                'source': {'url': SOURCE_URL, 'sha256': SOURCE_SHA, 'license': 'GPL-3.0-or-later'},
                'data_package': {'url': DATA_URL, 'tag': 'data-v8', 'sha256': DATA_SHA,
                                 'hash_authority': RAW + 'tools/release/data.lock'},
                'license_sources': license_evidence, 'data': data_records,
                'license_review': {
                    'scope': 'isolated local evaluation, no redistribution or license clearance claim',
                    'source': 'GPL-3.0-or-later; name/logo excluded',
                    'dictionary_gap': 'Packaged dict.qj metadata gives MIT AND Unicode-3.0 AND GPL-3.0-or-later; upstream landscape explicitly says standard-character/common-word transcription repositories lack licenses. Unresolved for redistribution.',
                    'statistical_model': 'Packaged lm.qj: CC-BY-SA-4.0 AND MIT (Wikipedia + LCCC)',
                    'general_dictionary': 'Packaged general.qj: GPL-3.0-or-later; provenance only described as cleaned open corpora, further audit required for redistribution.',
                    'unused_neural': 'Pack archive includes Tongbian; pack-model.sh says GPL-3.0-or-later and Wikipedia CC-BY-SA-3.0/GFDL + LCCC MIT + IndustryCorpus2 Apache-2.0. Unused; not an inference dependency.',
                    'english': 'ESDB MIT-like/WordNet notices; CSpell MIT; wordfreq frequency data attribution/share-alike; upstream source README governs',
                }, 'build_command': build, 'build_environment': {key: environment[key] for key in ('CARGO_HOME','CARGO_TARGET_DIR','CARGO_BUILD_JOBS')},
                'toolchain': {tool: subprocess.check_output([tool, '--version'], text=True).strip() for tool in ('cargo', 'rustc')},
                'app_assembly_evidence': [str(source / p) for p in (
                    'apps/macos/src/host/init.rs', 'apps/macos/src/host/config/mod.rs',
                    'apps/macos/src/imk/controller/commit.rs', 'apps/macos/src/imk/controller/command.rs',
                    'crates/qingjian-platform/src/extra_dictionaries.rs',
                    'crates/qingjian-platform/src/config/dictionaries.rs',
                    'crates/qingjian-core/src/engine/learning/muted.rs')],
                'status': 'data_verified_before_build'}
    def save():
        (ROOT / 'manifest.json').write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + '\n')
    save()
    run(build, env=environment)
    manifest['worker_source_sha256'] = sha(project / 'src/main.rs')
    manifest['binary_sha256'] = sha(Path(command[0]))
    manifest['cargo_lock_sha256'] = sha(project / 'Cargo.lock')
    manifest['build_command_locked_rerun'] = build + ['--locked']
    # Cargo metadata carries exact selected dependency licenses and source IDs.
    host = next(line.split(': ', 1)[1] for line in subprocess.check_output(
        ['rustc', '-vV'], text=True).splitlines() if line.startswith('host: '))
    metadata_command = ['cargo','metadata','--locked','--format-version','1',
                        '--filter-platform',host,'--manifest-path',str(project / 'Cargo.toml')]
    metadata = json.loads(subprocess.check_output(metadata_command, env=environment, text=True))
    (ROOT / 'cargo-metadata.json').write_text(json.dumps(metadata, indent=2) + '\n')
    manifest['dependency_licenses'] = [{'name': p['name'], 'version': p['version'], 'license':p['license'],
                                       'source':p['source']} for p in metadata['packages']]
    cases = HERE / 'input-engine-cases.json'
    layout = json.loads(subprocess.check_output([command[0], '--check-layout', str(cases)], text=True))
    assert not layout['mismatches'], layout
    manifest['layout_check'] = dict(layout, cases_sha256=sha(cases), generator_sha256=sha(HERE / 'prepare-input-engine-cases.py'))
    if not args.skip_smoke:
        result = smoke(command, ROOT / 'smoke.json')
        manifest['config'] = result['ready']['config']
        manifest['deviations'] = result['ready']['config']['deviations']
        manifest['smoke_candidates'] = result['known_candidates']
        manifest['smoke'] = str(ROOT / 'smoke.json')
    manifest['status'] = 'ready; smoke correctness only; formal performance not run'
    manifest['quality_performance_isolation'] = 'Core set_learning(false) actually mutes all learner writes; default NoLearner installed. Reset clears composition/held, breaks chain and forgets current input-box history. Main runner should still use separate quality/performance processes per plan.'
    save()
    print(str(ROOT / 'manifest.json'))


if __name__ == '__main__':
    main()
