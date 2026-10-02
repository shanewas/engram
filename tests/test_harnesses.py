"""Harness connect/disconnect and `engram init`, against a temp HOME. Never touches the real one."""
import json
import os
import shutil
import tempfile
import unittest
from pathlib import Path
from unittest import mock

from engram_sync import cli, harnesses as h
from tests.test_sync import git, write


class HarnessTests(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix='engram-home-'))
        self.home = self.tmp / 'home'
        self.repo = self.tmp / 'mem'
        (self.repo / 'skills' / 'mine').mkdir(parents=True)
        write(self.repo / 'skills' / 'mine' / 'SKILL.md', '---\nname: mine\n---\n')
        self.env = mock.patch.dict(os.environ, {'ENGRAM_USER_HOME': str(self.home), 'CODEX_HOME': ''})
        self.env.start()

    def tearDown(self):
        self.env.stop()
        shutil.rmtree(self.tmp, ignore_errors=True)

    def quiet(self, *_):
        pass

    def test_claude_connect_is_idempotent_and_keeps_user_content(self):
        claude = self.home / '.claude'
        write(claude / 'CLAUDE.md', '# my rules\n')
        write(claude / 'settings.json', json.dumps({'model': 'x', 'hooks': {'SessionStart': [
            {'matcher': '*', 'hooks': [{'type': 'command', 'command': 'echo mine'}]},
            {'matcher': '*', 'hooks': [{'type': 'command', 'command': 'powershell -File C:/u/engram/scripts/sync.ps1 pull'}]},
        ]}}))
        h.connect('claude', self.repo, out=self.quiet)
        h.connect('claude', self.repo, out=self.quiet)
        md = (claude / 'CLAUDE.md').read_text(encoding='utf-8')
        self.assertTrue(md.startswith('# my rules\n'))
        self.assertEqual(md.count(h.BEGIN), 1)
        self.assertIn('@%s/index.md' % h.fwd(self.repo), md)
        s = json.loads((claude / 'settings.json').read_text(encoding='utf-8'))
        starts = [x['command'] for g in s['hooks']['SessionStart'] for x in g['hooks']]
        self.assertEqual(s['model'], 'x')
        self.assertIn('echo mine', starts)
        self.assertFalse(any('sync.ps1' in c for c in starts))
        self.assertEqual(sum('engram_sync' in c for c in starts), 1)
        self.assertIn('--detach', s['hooks']['SessionEnd'][0]['hooks'][0]['command'])
        for skill in ('engram', 'engram-remember', 'engram-consolidate', 'mine'):
            self.assertTrue((claude / 'skills' / skill / 'SKILL.md').exists(), skill)
        self.assertTrue(h.is_connected('claude'))

    def test_existing_unmanaged_skill_is_never_replaced(self):
        write(self.home / '.codex' / 'skills' / 'engram-remember' / 'SKILL.md', 'user owned\n')
        h.connect('codex', self.repo, out=self.quiet)
        self.assertEqual((self.home / '.codex' / 'skills' / 'engram-remember' / 'SKILL.md').read_text(), 'user owned\n')
        self.assertTrue((self.home / '.codex' / 'skills' / 'engram' / h.OWNED).exists())
        self.assertIn(h.BEGIN, (self.home / '.codex' / 'AGENTS.md').read_text(encoding='utf-8'))

    def test_opencode_agents_md_not_created_when_absent(self):
        h.connect('opencode', self.repo, out=self.quiet)
        self.assertFalse((self.home / '.config' / 'opencode' / 'AGENTS.md').exists())
        write(self.home / '.config' / 'opencode' / 'AGENTS.md', '# oc\n')
        h.connect('opencode', self.repo, out=self.quiet)
        self.assertIn(h.BEGIN, (self.home / '.config' / 'opencode' / 'AGENTS.md').read_text(encoding='utf-8'))

    def test_disconnect_removes_only_what_it_added(self):
        claude = self.home / '.claude'
        write(claude / 'CLAUDE.md', '# my rules\n')
        write(claude / 'skills' / 'other' / 'SKILL.md', 'x\n')
        h.connect('claude', self.repo, out=self.quiet)
        h.disconnect('claude', self.repo, out=self.quiet)
        self.assertEqual((claude / 'CLAUDE.md').read_text(encoding='utf-8'), '# my rules\n')
        self.assertEqual(sorted(p.name for p in (claude / 'skills').iterdir()), ['other'])
        self.assertNotIn('hooks', json.loads((claude / 'settings.json').read_text(encoding='utf-8')))

    def test_refresh_updates_only_connected_harnesses(self):
        h.connect('antigravity', self.repo, out=self.quiet)
        write(self.repo / 'skills' / 'new' / 'SKILL.md', '---\nname: new\n---\n')
        h.refresh_connected(self.repo)
        self.assertTrue((self.home / '.gemini' / 'config' / 'skills' / 'new').exists())
        self.assertFalse((self.home / '.codex').exists())


class InitTests(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix='engram-init-'))
        self.origin = self.tmp / 'origin.git'
        git(self.tmp, 'init', '-q', '--bare', '-b', 'main', str(self.origin))
        self.env = mock.patch.dict(os.environ, {
            'ENGRAM_USER_HOME': str(self.tmp / 'home'), 'ENGRAM_HOST': 'pc1',
            'GIT_AUTHOR_NAME': 't', 'GIT_AUTHOR_EMAIL': 't@example.com',
            'GIT_COMMITTER_NAME': 't', 'GIT_COMMITTER_EMAIL': 't@example.com'})
        self.env.start()

    def tearDown(self):
        self.env.stop()
        shutil.rmtree(self.tmp, ignore_errors=True)

    def init(self, repo):
        return cli.main(['--repo', str(repo), 'init', str(self.origin), '--no-schedule'])

    def test_init_seeds_empty_remote_then_second_machine_joins(self):
        write(self.tmp / 'home' / '.claude' / 'CLAUDE.md', '')
        self.assertEqual(self.init(self.tmp / 'pc1'), 0)
        files = git(self.origin, 'ls-tree', '-r', '--name-only', 'HEAD').splitlines()
        for f in ('index.md', '.gitattributes', '.gitignore', '.engram/sync-paths.conf', 'projects/_template.md'):
            self.assertIn(f, files)
        self.assertTrue(h.is_connected('claude'))
        self.assertEqual(self.init(self.tmp / 'pc2'), 0)
        self.assertEqual(git(self.origin, 'rev-list', '--count', 'HEAD'), '1')

    def test_init_refuses_mismatched_origin_and_non_git_dir(self):
        self.assertEqual(self.init(self.tmp / 'pc1'), 0)
        git(self.tmp / 'pc1', 'remote', 'set-url', 'origin', 'https://example.com/other.git')
        self.assertEqual(self.init(self.tmp / 'pc1'), 1)
        write(self.tmp / 'junk' / 'f.txt', 'x')
        self.assertEqual(self.init(self.tmp / 'junk'), 1)

    def test_owner_name_shorthand(self):
        self.assertEqual(cli.expand_url('alice/memory'), 'https://github.com/alice/memory.git')
        self.assertEqual(cli.expand_url('git@github.com:alice/m.git'), 'git@github.com:alice/m.git')


if __name__ == '__main__':
    unittest.main()
