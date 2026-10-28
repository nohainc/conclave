#!/usr/bin/env python3
"""Executable repository contract tests using real dpkg and disposable GPG keys."""
import gzip
import hashlib
import importlib.util
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
import os
import sys
sys.dont_write_bytecode = True

spec = importlib.util.spec_from_file_location('apt_repository', Path(__file__).with_name('build-apt-repository.py'))
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


@unittest.skipUnless(all(shutil.which(tool) for tool in ('gpg', 'gpgv', 'dpkg-deb')), 'Needs GPG and dpkg')
class RepositoryTest(unittest.TestCase):
    def test_signed_indexes_retain_versions_and_reject_replacement(self):
        with tempfile.TemporaryDirectory(prefix='syntila-apt-') as temporary:
            root = Path(temporary)
            previous = os.environ.get('GNUPGHOME')
            os.environ['GNUPGHOME'] = str(root / 'gnupg')
            Path(os.environ['GNUPGHOME']).mkdir(mode=0o700)
            try:
                subprocess.run(['gpg', '--batch', '--pinentry-mode', 'loopback', '--passphrase', '',
                                '--quick-generate-key', 'APT test <test@example.invalid>', 'ed25519', 'sign', '1d'], check=True)
                key = next(line.split(':')[9] for line in module.run('gpg', '--with-colons', '--list-secret-keys').splitlines() if line.startswith('fpr:'))
                def package(version, arch, payload='original'):
                    stage = root / f'stage-{version}-{arch}'
                    (stage / 'DEBIAN').mkdir(parents=True, exist_ok=True)
                    (stage / 'DEBIAN/control').write_text(f'Package: syntila\nVersion: {version}\nArchitecture: {arch}\nMaintainer: Test <test@example.invalid>\nDescription: fixture\n')
                    (stage / 'payload').write_text(payload)
                    dest = root / f'{version}-{arch}.deb'
                    subprocess.run(['dpkg-deb', '--build', '--root-owner-group', str(stage), str(dest)], check=True, stdout=subprocess.DEVNULL)
                    return dest
                output = root / 'repository'
                old = package('1.0.0', 'amd64')
                module.build(output, [old], key)
                old_index = (output / 'dists/stable/main/binary-amd64/Packages').read_bytes()
                module.build(output, [package('1.0.1', 'amd64'), package('1.0.1', 'arm64')], key)
                index = output / 'dists/stable/main/binary-amd64/Packages'
                content = index.read_bytes()
                self.assertIn(b'Version: 1.0.0\n', content)
                self.assertIn(b'Version: 1.0.1\n', content)
                self.assertEqual(gzip.decompress(index.with_name('Packages.gz').read_bytes()), content)
                # Old by-hash indexes remain available to clients mid-update.
                self.assertTrue((index.parent / 'by-hash/SHA256' / hashlib.sha256(old_index).hexdigest()).exists())
                for paragraph in content.decode().strip().split('\n\n'):
                    fields = dict(line.split(': ', 1) for line in paragraph.splitlines() if ': ' in line and not line.startswith(' '))
                    payload = (output / fields['Filename']).read_bytes()
                    self.assertEqual(hashlib.sha256(payload).hexdigest(), fields['SHA256'])
                subprocess.run(['gpgv', '--keyring', str(output / 'syntila-archive-keyring.gpg'), str(output / 'dists/stable/InRelease')], check=True)
                # Exercise the real publisher against a local bare git remote,
                # with only GitHub transport mocked. No production credentials.
                remote = root / 'remote.git'
                subprocess.run(['git', 'init', '--quiet', '--bare', str(remote)], check=True)
                wrappers = root / 'bin'
                wrappers.mkdir()
                real_git = shutil.which('git')
                (wrappers / 'gh').write_text("#!/bin/sh\ncase \"$*\" in *visibility*) echo PUBLIC ;; esac\n")
                (wrappers / 'git').write_text(
                    "#!/usr/bin/env python3\nimport os,sys\n"
                    "args=[os.environ['APT_TEST_REMOTE'] if arg=='https://github.com/test/apt.git' else arg for arg in sys.argv[1:]]\n"
                    "os.execv(os.environ['APT_TEST_GIT'],[os.environ['APT_TEST_GIT'],*args])\n")
                for wrapper in wrappers.iterdir():
                    wrapper.chmod(0o755)
                private = subprocess.check_output(['gpg', '--batch', '--armor', '--export-secret-keys', key], text=True)
                publisher_env = dict(os.environ, PATH=str(wrappers) + os.pathsep + os.environ['PATH'],
                                     APT_TEST_REMOTE=str(remote), APT_TEST_GIT=real_git,
                                     SYNTILA_APT_PRIVATE_KEY=private, SYNTILA_APT_SIGNING_FINGERPRINT=key,
                                     GITHUB_REPOSITORY='test/apt', GITHUB_REF='refs/heads/main', GH_TOKEN='fixture')
                publisher = Path(__file__).with_name('publish-apt-repository.sh').resolve()
                exported = root / 'site'
                for version in ('2.0.0', '2.0.1'):
                    candidates = root / ('candidates-' + version)
                    candidates.mkdir()
                    for arch in ('amd64', 'arm64'):
                        shutil.copyfile(package(version, arch), candidates / f'{arch}.deb')
                    publisher_env['SYNTILA_WORKSPACE_VERSION'] = version
                    result = subprocess.run(['bash', str(publisher), str(candidates), str(exported)],
                                            env=publisher_env, capture_output=True, text=True)
                    self.assertEqual(result.returncode, 0, result.stderr)
                self.assertFalse((exported / '.git').exists())
                self.assertEqual({item.name for item in exported.iterdir()},
                                 {'pool', 'dists', 'syntila-archive-keyring.gpg', '.nojekyll', 'index.html'})
                self.assertEqual(len(list((exported / 'pool').rglob('*.deb'))), 4)
                self.assertIn(key, (exported / 'index.html').read_text())
                self.assertNotIn('PRIVATE KEY', (exported / 'index.html').read_text())
                with self.assertRaisesRegex(ValueError, 'immutable'):
                    module.build(output, [package('1.0.0', 'amd64', 'changed')], key)
                signed = output / 'dists/stable/InRelease'
                signed.write_bytes(signed.read_bytes().replace(b'Origin: Syntila', b'Origin: Tampered'))
                self.assertNotEqual(subprocess.run(['gpgv', '--keyring', str(output / 'syntila-archive-keyring.gpg'), str(signed)], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode, 0)
            finally:
                subprocess.run(['gpgconf', '--kill', 'gpg-agent'], check=False)
                if previous is None:
                    os.environ.pop('GNUPGHOME', None)
                else:
                    os.environ['GNUPGHOME'] = previous


if __name__ == '__main__':
    unittest.main()
