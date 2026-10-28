"""Harness connect/disconnect and `engram init`, against a temp HOME. Never touches the real one."""
import json
import os
import shutil
import stat
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

    def test_adopt_replaces_foreign_dir_and_marks_it(self):
        skills = self.home / '.codex' / 'skills'
        write(skills / 'mine' / 'SKILL.md', 'stale copy\n')
        h.connect('codex', self.repo, out=self.quiet, adopt=True)
        self.assertIn('name: mine', (skills / 'mine' / 'SKILL.md').read_text(encoding='utf-8'))
        self.assertTrue((skills / 'mine' / h.OWNED).exists())

    def test_refresh_replaces_read_only_files_and_skips_git_dir(self):
        write(self.repo / 'skills' / 'mine' / '.git' / 'HEAD', 'ref: refs/heads/main\n')
        skills = self.home / '.codex' / 'skills'
        h.connect('codex', self.repo, out=self.quiet)
        self.assertFalse((skills / 'mine' / '.git').exists())
        pack = skills / 'mine' / 'pack.idx'
        write(pack, 'x')
        os.chmod(pack, stat.S_IREAD)
        h.copy_skills(self.repo, skills, out=self.quiet)
        self.assertFalse(pack.exists())

    def test_dot_claude_skills_layout_is_a_source_and_wins_clashes(self):
        write(self.repo / '.claude' / 'skills' / 'legacy' / 'SKILL.md', '---\nname: legacy\n---\n')
        write(self.repo / '.claude' / 'skills' / 'mine' / 'SKILL.md', '---\nname: mine-v2\n---\n')
        (self.repo / '.claude' / 'skills' / 'category').mkdir()
        h.connect('codex', self.repo, out=self.quiet)
        skills = self.home / '.codex' / 'skills'
        self.assertTrue((skills / 'legacy' / 'SKILL.md').exists())
        self.assertIn('mine-v2', (skills / 'mine' / 'SKILL.md').read_text(encoding='utf-8'))
        self.assertFalse((skills / 'category').exists())

    def test_skills_only_leaves_instructions_and_settings_alone(self):
        claude = self.home / '.claude'
        write(claude / 'CLAUDE.md', '# managed elsewhere\n')
        h.connect('claude', self.repo, out=self.quiet, skills_only=True)
        self.assertEqual((claude / 'CLAUDE.md').read_text(encoding='utf-8'), '# managed elsewhere\n')
        self.assertFalse((claude / 'settings.json').exists())
        self.assertTrue((claude / 'skills' / 'engram' / h.OWNED).exists())

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

    def test_reversed_markers_do_not_crash(self):
        path = self.tmp / 'CLAUDE.md'
        original = '# rules\n%s\n%s\n' % (h.END, h.BEGIN)
        write(path, original)
        h.remove_block(path)
        self.assertEqual(path.read_text(encoding='utf-8'), original)
        h.upsert_block(path, h.block(self.repo, False))
        text = path.read_text(encoding='utf-8')
        self.assertTrue(text.startswith(original))
        self.assertIn('# Engram memory', text[len(original):])

    def test_atomic_writes_leave_no_temp_files(self):
        md = self.tmp / 'atomic' / 'CLAUDE.md'
        write(md, '# mine\n')
        h.upsert_block(md, h.block(self.repo, False))
        self.assertEqual([p.name for p in md.parent.iterdir()], ['CLAUDE.md'])
        self.assertIn(h.BEGIN, md.read_text(encoding='utf-8'))
        spec = h.registry()['claude']
        write(spec['settings'], json.dumps({'model': 'x'}))
        h.set_claude_hooks(spec, self.repo, True)
        self.assertEqual([p.name for p in spec['settings'].parent.iterdir()], ['settings.json'])
        self.assertIn('hooks', json.loads(spec['settings'].read_text(encoding='utf-8')))

    def test_set_claude_hooks_rejects_malformed_settings(self):
        spec = h.registry()['claude']
        for text in ('[1, 2]', 'not json', '{"hooks": []}',
                     '{"hooks": {"SessionStart": {}}}', '{"hooks": {"SessionStart": ["x"]}}'):
            with self.subTest(text=text):
                write(spec['settings'], text)
                with self.assertRaises(ValueError):
                    h.set_claude_hooks(spec, self.repo, True)
                self.assertFalse(h.has_claude_hooks(spec))

    def test_failed_skill_copy_keeps_old_destination(self):
        dest_root = self.tmp / 'dest-skills'
        h.copy_skills(self.repo, dest_root, out=self.quiet)
        dest = dest_root / 'mine'
        old = (dest / 'SKILL.md').read_text(encoding='utf-8')
        write(dest / 'keep.txt', 'keep\n')
        before = sorted(p.name for p in dest_root.iterdir())
        try:
            os.symlink(str(self.repo / 'skills' / 'mine' / 'missing'),
                       str(self.repo / 'skills' / 'mine' / 'broken'))
        except (OSError, NotImplementedError):
            self.skipTest('symlinks not permitted here')
        with self.assertRaises(shutil.Error):
            h.copy_skills(self.repo, dest_root, out=self.quiet)
        self.assertEqual((dest / 'SKILL.md').read_text(encoding='utf-8'), old)
        self.assertEqual((dest / 'keep.txt').read_text(encoding='utf-8'), 'keep\n')
        self.assertTrue((dest / h.OWNED).exists())
        self.assertEqual(sorted(p.name for p in dest_root.iterdir()), before)

    def test_refresh_updates_only_connected_harnesses(self):
        h.connect('antigravity', self.repo, out=self.quiet)
        write(self.repo / 'skills' / 'new' / 'SKILL.md', '---\nname: new\n---\n')
        h.refresh_connected(self.repo)
        self.assertTrue((self.home / '.gemini' / 'config' / 'skills' / 'new').exists())
        self.assertFalse((self.home / '.codex').exists())


class ScheduleTests(unittest.TestCase):
    def run_schedule(self, list_result):
        calls = []

        def fake_run(cmd, **kw):
            calls.append(cmd)
            if cmd == ['crontab', '-l']:
                return list_result
            return mock.Mock(returncode=0, stdout='', stderr='')

        with mock.patch.object(cli.subprocess, 'run', side_effect=fake_run), \
                mock.patch.object(cli.shutil, 'which', return_value='/usr/bin/crontab'):
            result = cli.schedule(Path('/tmp/mem'), True)
        return result, calls

    def test_schedule_other_crontab_failure_does_not_install(self):
        (ok, msg), calls = self.run_schedule(
            mock.Mock(returncode=1, stdout='', stderr='crontab: permission denied\n'))
        self.assertFalse(ok)
        self.assertIn('permission denied', msg)
        self.assertEqual(calls, [['crontab', '-l']])

    def test_schedule_no_crontab_installs(self):
        (ok, _msg), calls = self.run_schedule(
            mock.Mock(returncode=1, stdout='', stderr='no crontab for tester\n'))
        self.assertTrue(ok)
        self.assertIn(['crontab', '-'], calls)


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
        self.assertEqual(git(self.origin, 'log', '--format=%s', 'HEAD').count('engram: initialize'), 1)

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
