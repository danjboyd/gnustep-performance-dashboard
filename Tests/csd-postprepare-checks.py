#!/usr/bin/env python3
"""Fresh runner-layout post-prepare simulation; all acquisition is synthetic."""
import contextlib
import importlib.util
import io
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import unittest
from unittest.mock import patch

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[1]


def module(name, relative):
    spec = importlib.util.spec_from_file_location(name, ROOT / relative)
    value = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(value)
    return value


sources = module('source_fixtures', 'Tests/csd-source-checks.py')
artifacts = module('artifact_fixtures', 'Tests/csd-final-review-checks.py')
core = module('shared_collector', 'scripts/collect-release-sources.py')
wrapper = module('thin_collector', 'scripts/collect-csd-sources.py')
final = artifacts.final


class PostPrepareChecks(unittest.TestCase):
    def test_fresh_numeric_pipeline_collects_verifies_aggregates_and_prepares_upload(self):
        src = sources.CSDSourceChecks(); src.setUp(); self.addCleanup(src.doCleanups)
        pkg = artifacts.FinalReviewChecks(); pkg.use_real_gates = True
        with patch.object(artifacts, 'VERSION', '0.1.7'), patch.object(artifacts, 'BASE', 'PerformanceDashboard-0.1.7-x86_64'), patch.object(artifacts, 'COMMIT', sources.COMMIT):
            pkg.setUp()
        self.addCleanup(pkg.doCleanups)
        repo = src.project.resolve(); work = repo / 'out/csd-ci'; sdk = work / 'sdk'
        sdk.mkdir(parents=True); (work / 'logs').mkdir()
        for relative in ('scripts/verify-csd-sources.py', '.github/scripts/csd-review-state.py',
                         'packaging/linux/v017-backend-needed.json', 'packaging/linux/release-production.json',
                         'packaging/package.manifest.json'):
            target = repo / relative; target.parent.mkdir(parents=True, exist_ok=True); shutil.copy2(ROOT / relative, target)
        for name in ('gnustep-toolchain-provenance.json', 'pd-csd-build-sources.json', 'pd-csd-cache-receipt.json'):
            shutil.copy2(src.tree / 'metadata' / name, sdk / name)
        provenance = json.loads((sdk / 'gnustep-toolchain-provenance.json').read_text())
        provenance.update(schema_version=1, kind='custom-gnustep-toolchain-provenance', install_domain='LOCAL', prefix=str(sdk))
        self.write(sdk / 'gnustep-toolchain-provenance.json', provenance)
        state = dict(builderCommit=src.config['builder']['revision'], cacheIdentity='d'*64, reviewImageID='sha256:'+'c'*64)
        theme = json.loads((src.tree / 'metadata/theme-receipt.json').read_text())
        theme['toolchainProvenanceSHA256'] = final.policy.sha(sdk / 'gnustep-toolchain-provenance.json')
        self.write(work / 'theme-receipt.json', theme); self.write(work / 'container-inputs.json', state)
        cache = dict(lockSHA256=src.lock_sha, sdkProvenanceSHA256=theme['toolchainProvenanceSHA256'],
            buildSourcesSHA256=final.policy.sha(sdk / 'pd-csd-build-sources.json'), backendBuildLogSHA256='e'*64,
            cacheKey=final.policy.cache_key(repo, state), buildContainerInputs=state)
        self.write(sdk / 'pd-csd-cache-receipt.json', cache)
        licenses = repo / 'dist/stage/metadata/licenses'; licenses.mkdir(parents=True)
        shutil.copy2(src.tree / 'metadata/host-libraries.txt', licenses / 'host-libraries.txt')
        shutil.copy2(repo / src.config['lock'], licenses.parent / 'custom-toolchain-lock.json')
        shutil.copy2(sdk / 'gnustep-toolchain-provenance.json', licenses.parent / 'custom-toolchain-provenance.json')
        packages = repo / 'dist/packages'; packages.mkdir()
        for name in final.names('0.1.7'): shutil.copy2(pkg.directory / name, packages / name)
        base = 'PerformanceDashboard-0.1.7-x86_64'
        prov = json.loads((packages / (base+'.provenance.json')).read_text())
        prov['inputs']['customToolchain'].update(lockSHA256=src.lock_sha, sdkProvenanceSHA256=theme['toolchainProvenanceSHA256'])
        prov['inputs']['adwaita']['buildReceipt'] = theme
        self.write(packages / (base+'.provenance.json'), prov)
        closure = dict(appImage=final.file_record(packages / (base+'.AppImage')),
            provenanceSHA256=final.policy.sha(packages / (base+'.provenance.json')),
            selectedPayloadSHA256={k:v['sha256'] for k,v in final.provenance_ties(prov).items()}, closure={'elfCount': 1})
        self.write(work / 'logs/payload-closure.json', closure)
        self.write(work / 'logs/backend-closure.json', dict(unexpected=[], backendBuildLogSHA256='e'*64))
        output = repo / 'dist/ci/csd-review'
        final.prepare(packages, output, '0.1.7')  # parent absent, exactly like first runner
        archives = {r['archiveURL']: src.tree / r['archiveFile'] for r in src.manifest['gitSources']}
        fetched = []
        checked_tools = []
        def which(command):
            self.assertFalse(fetched)
            checked_tools.append(command); return "/synthetic/bin/" + command
        def urlopen(url):
            fetched.append(url); return io.BytesIO(archives[url].read_bytes())
        def git(directory, *args):
            if args[0] == 'status': return ''
            if args[0] == 'rev-parse': return core.BUILDER if Path(directory).name == 'builder' else sources.COMMIT
            self.assertEqual(args[0], 'archive')
            entry = next(r for r in src.manifest['gitSources'] if r['name'] == 'gnustep-cli-new')
            shutil.copy2(src.tree / entry['archiveFile'], Path(args[args.index('-o')+1])); return ''
        def check_output(command, **kwargs):
            if command[0] == 'dpkg-query': return 'fixture\t1.0'
            if command[0] == 'git': return sources.COMMIT if 'rev-parse' in command else ''
            self.fail('unexpected external command: ' + str(command))
        def run(command, cwd, **kwargs):
            self.assertTrue(Path(cwd).is_absolute())
            if command[0] == 'apt-get':
                self.assertEqual(command, ['apt-get', 'source', '--download-only', 'fixture=1.0'])
                for file in (src.tree / 'debian').iterdir(): shutil.copy2(file, Path(cwd) / file.name)
            else:
                self.assertEqual(command[:2], ['git', 'archive'])
                shutil.copy2(src.tree / 'PerformanceDashboard.tar', command[command.index('-o')+1])
            return subprocess.CompletedProcess(command, 0)
        with patch.object(core, 'root', repo): verifier = core.evidence_module()
        with contextlib.chdir(repo), contextlib.redirect_stdout(io.StringIO()), \
             patch.object(core, 'root', repo), patch.object(core, 'git', side_effect=git), \
             patch.object(core, 'evidence_module', return_value=verifier), \
             patch.object(verifier.policy, 'validate_sdk', return_value=None), \
             patch.object(wrapper, 'module', return_value=core), \
             patch.object(core.urllib.request, 'urlopen', side_effect=urlopen), \
             patch.object(core.shutil, 'which', side_effect=which), \
             patch.object(core.subprocess, 'check_output', side_effect=check_output), \
             patch.object(core.subprocess, 'run', side_effect=run), patch.dict(os.environ, CSD_MODE='production'):
            result = wrapper.collect(repo, '0.1.7', Path('dist/ci/csd-review'), sdk)
        self.assertEqual(result['gitSourceCount'], 14); self.assertEqual(result['patchCount'], 16)
        self.assertEqual(checked_tools, ['apt-get', 'dpkg-query', 'dpkg-source'])
        self.assertEqual(len(fetched), 13)  # builder source comes from local git archive
        self.write(work / 'logs/sources-verification.json', result)
        for source in (work / 'container-inputs.json', work / 'theme-receipt.json', sdk / 'pd-csd-cache-receipt.json',
                       work / 'logs/backend-closure.json', work / 'logs/payload-closure.json', work / 'logs/sources-verification.json'):
            shutil.copy2(source, output / source.name)
        with patch.object(final.subprocess, 'check_output', side_effect=check_output):
            receipt = final.inventory(repo, output, '0.1.7')
            (output / final.RECEIPT).write_text(final.canonical(receipt))
            self.assertRegex(final.verify_receipt(repo, output, '0.1.7'), '^[0-9a-f]{64}$')
        self.assertEqual(receipt['applicationCommit'], sources.COMMIT)
        self.assertEqual(len(receipt['files']), 13)
        self.assertEqual(len(list(output.iterdir())), 14)  # 13 files plus canonical receipt
        self.assertIn('path: dist/ci/csd-review', (ROOT / '.github/workflows/csd-review.yml').read_text())

    def test_source_tools_are_installed_and_missing_dpkg_source_fails_before_acquisition(self):
        recipe = (ROOT / '.github/containers/csd-review.Dockerfile').read_text()
        self.assertIn('dpkg-dev', recipe)
        with patch.object(core.shutil, 'which', side_effect=lambda command: None if command == 'dpkg-source' else '/fixture/'+command):
            with self.assertRaisesRegex(ValueError, 'dpkg-dev'):
                core.check_source_tools()

    @staticmethod
    def write(path, value): path.write_text(json.dumps(value))


if __name__ == '__main__':
    unittest.main()
