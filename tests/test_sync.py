"""Contract tests for docs/sync-contract.md. Hermetic: temp bare origin + clones, no network."""
import datetime
import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

from engram_sync.sync import Sync, iso_now


def git(cwd, *args, check=True):
    r = subprocess.run(['git'] + list(args), cwd=str(cwd), capture_output=True, encoding='utf-8', errors='replace')
    if check and r.returncode != 0:
        raise AssertionError('git %s failed: %s' % (' '.join(args), r.stderr))
    return r.stdout.strip()


def write(path, text):
    path.parent.mkdir(parents=True, exist_ok=True)
    with open(path, 'w', encoding='utf-8', newline='\n') as f:
        f.write(text)


class Base(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix='engram-test-'))
        self.origin = self.tmp / 'origin.git'
        git(self.tmp, 'init', '-q', '--bare', '-b', 'main', str(self.origin))
        seed = self.tmp / 'seed'
        git(self.tmp, 'clone', '-q', str(self.origin), str(seed))
        self.ident(seed)
        write(seed / 'index.md', '# index\n')
        write(seed / '.gitattributes', 'inbox/** merge=union\nprojects/** merge=union\n')
        write(seed / '.gitignore', 'ALERT.md\n')
        git(seed, 'add', '-A')
        git(seed, 'commit', '-q', '-m', 'seed')
        git(seed, 'push', '-q', '-u', 'origin', 'main')
        self.a = self.clone('a')
        self.b = self.clone('b')

    def tearDown(self):
        shutil.rmtree(self.tmp, onerror=lambda f, p, e: (os.chmod(p, 0o700), f(p)))

    def ident(self, repo):
        git(repo, 'config', 'user.name', 'test')
        git(repo, 'config', 'user.email', 'test@example.com')
        git(repo, 'config', 'core.autocrlf', 'false')

    def clone(self, name):
        path = self.tmp / name
        git(self.tmp, 'clone', '-q', str(self.origin), str(path))
        self.ident(path)
        return path

    def sync(self, repo, mode, host='node'):
        out = []
        os.environ['ENGRAM_HOST'] = host
        Sync(repo, out=out.append).run(mode)
        return '\n'.join(out)

    def state(self, repo):
        return (repo / '.git' / 'engram-state').read_text(encoding='utf-8')

    def origin_files(self):
        return git(self.origin, 'ls-tree', '-r', '--name-only', 'main').splitlines()


class TestContract(Base):
    def test_push_then_pull(self):
        write(self.a / 'projects' / 'x.md', '- fact\n')
        self.sync(self.a, 'push')
        self.assertIn('projects/x.md', self.origin_files())
        self.assertTrue(self.state(self.a).startswith('ok '))
        self.assertRegex(git(self.origin, 'log', '-1', '--format=%s', 'main'), r'^sync\(node\): \d{4}-')
        self.sync(self.b, 'pull')
        self.assertTrue((self.b / 'projects' / 'x.md').exists())

    def test_allowlist_blocks_other_paths(self):
        write(self.a / 'scripts' / 'evil.sh', 'x\n')
        write(self.a / 'notes.txt', 'x\n')
        write(self.a / 'inbox' / '2026-01.md', '- ok\n')
        self.sync(self.a, 'push')
        files = self.origin_files()
        self.assertIn('inbox/2026-01.md', files)
        self.assertNotIn('scripts/evil.sh', files)
        self.assertNotIn('notes.txt', files)

    def test_allowlist_deletion_syncs(self):
        write(self.a / 'projects' / 'gone.md', 'x\n')
        self.sync(self.a, 'push')
        (self.a / 'projects' / 'gone.md').unlink()
        self.sync(self.a, 'push')
        self.assertNotIn('projects/gone.md', self.origin_files())

    def test_secret_scan_refuses_and_alerts(self):
        for secret in ('AKIA' + 'ABCDEFGHIJKLMNOP', 'ghp_' + 'a' * 36, '-----BEGIN RSA PRIVATE KEY-----'):
            with self.subTest(secret=secret[:6]):
                write(self.a / 'inbox' / 's.md', '- %s\n' % secret)
                self.sync(self.a, 'push')
                self.assertNotIn('inbox/s.md', self.origin_files())
                self.assertEqual(git(self.a, 'diff', '--cached', '--name-only'), '')
                alert = (self.a / 'ALERT.md').read_text(encoding='utf-8')
                self.assertNotIn(secret, alert)
                self.assertIn('engram:not-a-secret', alert)

    def test_secret_marker_exempts_line(self):
        write(self.a / 'inbox' / 's.md', '- token: cfat_REDACTEDREDACTED <!-- engram:not-a-secret -->\n')
        self.sync(self.a, 'push')
        self.assertIn('inbox/s.md', self.origin_files())
        write(self.a / 'inbox' / 's.md', '- token: cfat_REDACTEDREDACTED <!-- engram:not-a-secret -->\n- token: cfat_REDACTEDREDACTED\n')
        self.sync(self.a, 'push')
        self.assertTrue((self.a / 'ALERT.md').exists())

    def test_union_merge_keeps_both_lines(self):
        write(self.a / 'inbox' / 'm.md', '- base\n')
        self.sync(self.a, 'push')
        self.sync(self.b, 'pull')
        write(self.a / 'inbox' / 'm.md', '- base\n- from a\n')
        write(self.b / 'inbox' / 'm.md', '- base\n- from b\n')
        self.sync(self.a, 'push', host='a')
        self.sync(self.b, 'push', host='b')
        self.assertFalse((self.b / 'ALERT.md').exists())
        merged = git(self.origin, 'show', 'main:inbox/m.md')
        self.assertIn('from a', merged)
        self.assertIn('from b', merged)

    def test_modify_delete_conflict_escalates(self):
        write(self.a / 'projects' / 'p.md', 'v1\n')
        self.sync(self.a, 'push', host='a')
        self.sync(self.b, 'pull', host='b')
        (self.a / 'projects' / 'p.md').unlink()
        self.sync(self.a, 'push', host='a')
        write(self.b / 'projects' / 'p.md', 'v2\n')
        out = self.sync(self.b, 'push', host='b')
        self.assertIn('conflict/b', git(self.origin, 'branch', '--list'))
        self.assertIn('nothing is lost', (self.b / 'ALERT.md').read_text(encoding='utf-8'))
        self.assertIn('Engram sync ALERT', out)
        self.assertTrue(self.state(self.b).startswith('err '))
        self.assertFalse((self.b / '.git' / 'rebase-merge').exists())

    def test_alert_printed_on_pull_and_cleared_on_success(self):
        write(self.a / 'ALERT.md', '# Engram sync ALERT\nstale\n')
        self.sync(self.a, 'pull')
        self.assertFalse((self.a / 'ALERT.md').exists())
        self.sync(self.a, 'pull')
        write(self.a / 'ALERT.md', '# Engram sync ALERT\nstill broken\n')
        git(self.a, 'remote', 'set-url', 'origin', str(self.tmp / 'missing.git'))
        self.assertIn('still broken', self.sync(self.a, 'pull'))

    def test_lock_fresh_blocks_stale_is_stolen(self):
        lock = self.a / '.git' / 'engram-sync.lock'
        write(lock, '1 %s\n' % iso_now())
        write(self.a / 'inbox' / 'l.md', '- x\n')
        self.sync(self.a, 'push')
        self.assertNotIn('inbox/l.md', self.origin_files())
        old = (datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(minutes=10)).strftime('%Y-%m-%dT%H:%M:%SZ')
        write(lock, '1 %s\n' % old)
        self.sync(self.a, 'push')
        self.assertIn('inbox/l.md', self.origin_files())
        self.assertFalse(lock.exists())

    def test_readonly_node_never_pushes(self):
        write(self.a / '.git' / 'engram-readonly', '')
        write(self.a / 'inbox' / 'r.md', '- x\n')
        self.sync(self.a, 'push')
        self.assertNotIn('inbox/r.md', self.origin_files())
        self.assertEqual(git(self.a, 'log', '-1', '--format=%s'), 'seed')

    def test_unreachable_remote_reports_offline(self):
        git(self.a, 'remote', 'set-url', 'origin', str(self.tmp / 'missing.git'))
        out = self.sync(self.a, 'pull')
        self.assertIn('did not sync (offline?)', out)
        self.assertTrue(self.state(self.a).startswith('err '))
        self.assertFalse((self.a / 'ALERT.md').exists())

    def test_not_a_git_repo_returns(self):
        plain = self.tmp / 'plain'
        plain.mkdir()
        self.assertIn('not a git repo', self.sync(plain, 'pull'))

    def test_allowlist_conf_and_unsafe_entries(self):
        write(self.a / '.engram' / 'sync-paths.conf', 'notes/  # mine\n../outside\n/abs\n')
        write(self.a / 'notes' / 'n.md', 'x\n')
        write(self.a / 'inbox' / 'i.md', 'x\n')
        self.sync(self.a, 'push')
        files = self.origin_files()
        self.assertIn('notes/n.md', files)
        self.assertNotIn('inbox/i.md', files)

    def test_no_origin_warns(self):
        git(self.a, 'remote', 'remove', 'origin')
        self.assertIn('NOT CONNECTED', self.sync(self.a, 'push'))
        self.assertIn('no origin remote', self.state(self.a))

    def test_consolidate_nudge(self):
        old = (datetime.date.today() - datetime.timedelta(days=9)).isoformat()
        write(self.a / 'archive' / 'consolidate-log.md', '- %s a\n' % old)
        self.assertIn('consolidat', self.sync(self.a, 'pull'))
        write(self.a / 'archive' / 'consolidate-log.md', '- %s a\n' % datetime.date.today().isoformat())
        self.assertNotIn('consolidat', self.sync(self.a, 'pull'))

    def test_pull_drains_unpushed_commit(self):
        write(self.a / 'inbox' / 'd.md', '- x\n')
        git(self.a, 'add', '-A')
        git(self.a, 'commit', '-q', '-m', 'left behind')
        self.sync(self.a, 'pull')
        self.assertIn('inbox/d.md', self.origin_files())

    def test_remote_guard_keeps_core_sshcommand(self):
        git(self.a, 'config', 'core.sshCommand', 'myssh -i key')
        git(self.a, 'config', 'alias.showssh', '!echo "$GIT_SSH_COMMAND|$GIT_TERMINAL_PROMPT|$GCM_INTERACTIVE"')
        rc, out = Sync(self.a).git('showssh', remote=True)
        self.assertEqual(out.strip(), 'myssh -i key -o BatchMode=yes -o ConnectTimeout=10|0|never')

    def test_conflict_self_heal_aborts_leftover_rebase(self):
        write(self.b / 'index.md', '# from b\n')
        git(self.b, 'commit', '-q', '-am', 'b')
        git(self.b, 'push', '-q')
        write(self.a / 'index.md', '# from a\n')
        git(self.a, 'commit', '-q', '-am', 'a')
        git(self.a, 'pull', '-q', '--rebase', check=False)
        self.assertTrue((self.a / '.git' / 'rebase-merge').exists())
        self.sync(self.a, 'pull')
        self.assertFalse((self.a / '.git' / 'rebase-merge').exists())

    def test_refresh_skills_called_only_on_success(self):
        calls = []
        Sync(self.a, out=lambda m: None, refresh_skills=calls.append).run('pull')
        git(self.a, 'remote', 'set-url', 'origin', str(self.tmp / 'missing.git'))
        Sync(self.a, out=lambda m: None, refresh_skills=calls.append).run('pull')
        self.assertEqual(len(calls), 1)


if __name__ == '__main__':
    unittest.main()
