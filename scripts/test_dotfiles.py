import importlib, json, os, shutil, sys, tempfile, unittest
from pathlib import Path


class Base(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())
        self.repo = self.tmp / 'repo'
        self.home = self.tmp / 'home'
        self.cfg = self.tmp / 'cfg'
        (self.repo / '.git').mkdir(parents=True)
        (self.repo / '.git' / 'engram-apply-dotfiles').touch()
        (self.repo / 'dotfiles' / 'hosts').mkdir(parents=True)
        (self.repo / 'dotfiles' / 'claude').mkdir()
        (self.repo / 'dotfiles' / 'claude' / 'hooks').mkdir()
        (self.repo / 'plugins' / 'engram' / 'skills').mkdir(parents=True)
        self.home.mkdir()
        self.cfg.mkdir()
        os.environ['DOTFILES_REPO'] = str(self.repo)
        os.environ['DOTFILES_HOME'] = str(self.home)
        os.environ['DOTFILES_APPDATA'] = str(self.home / 'appdata')
        os.environ['DOTFILES_CONFIG'] = str(self.cfg)
        sys.path.insert(0, str(Path(__file__).parent))
        import dotfiles
        self.d = importlib.reload(dotfiles)
        self.host_file = self.repo / 'dotfiles' / 'hosts' / f'{self.d.HOST}.json'
        self.w(self.host_file, json.dumps({'vars': {'nick': 'office-box'}, 'overlay': {}, 'append': {}}))
        self.w(self.cfg / 'secrets.env', 'GITHUB_TOKEN=ghp_abcdefghijklmnopqrstuvwxyz0123456789\n')  # engram:not-a-secret
        self.targets = self.repo / 'dotfiles' / 'targets.conf'
        self.targets.write_text(
            'file|claude/settings.json.tmpl|{{HOME}}/.claude/settings.json\n'
            'dir|claude/hooks|{{HOME}}/.claude/hooks|exclude=gmail-*\n', encoding='utf-8')
        self.tmpl = self.repo / 'dotfiles' / 'claude' / 'settings.json.tmpl'
        self.w(self.tmpl, '{\n  "env": {\n    "GITHUB_TOKEN": "{{SECRET:GITHUB_TOKEN}}"\n  },\n  "hooks": {\n    "SessionStart": [\n      {\n        "cmd": "python \\"{{HOME_JSON}}\\\\x.py\\""\n      }\n    ]\n  },\n  "nick": "{{VAR:nick}}"\n}\n')
        (self.repo / 'dotfiles' / 'claude' / 'hooks' / 'a.py').write_bytes(b'print(1)\n')
        self.dest = self.home / '.claude' / 'settings.json'

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def w(self, p, s):
        # newline='' keeps LF on Windows; Path.write_text would emit CRLF
        with open(p, 'w', encoding='utf-8', newline='') as f:
            f.write(s)

    def state(self):
        return json.loads((self.cfg / 'state.json').read_text(encoding='utf-8'))


class RenderTests(Base):
    def test_render_and_unrender_roundtrip(self):
        host, secrets = self.d.load_host(), self.d.load_secrets()
        src = self.tmpl.read_text(encoding='utf-8')
        out = self.d.render(src, host, secrets)
        self.assertIn('ghp_abcdefghijklmnopqrstuvwxyz0123456789', out)  # engram:not-a-secret
        self.assertIn('office-box', out)
        self.assertIn(str(self.home).replace('\\', '\\\\'), out)
        self.assertNotIn('{{', out)
        self.assertEqual(self.d.unrender(out, host, secrets), src)

    def test_missing_secret_raises(self):
        with self.assertRaises(self.d.MissingKey):
            self.d.render('{{SECRET:NOPE}}', self.d.load_host(), {})

    def test_merge_unmerge_lists_and_dicts(self):
        base = {'hooks': {'S': [{'a': 1}]}, 'x': 1}
        over = {'hooks': {'S': [{'b': 2}]}}
        merged = self.d.merge(json.loads(json.dumps(base)), over)
        self.assertEqual(merged['hooks']['S'], [{'a': 1}, {'b': 2}])
        self.assertEqual(self.d.unmerge(merged, over), base)

    def test_unmerge_keeps_base_item_equal_to_overlay_item(self):
        base = {'S': [{'a': 1}]}
        over = {'S': [{'a': 1}]}
        merged = self.d.merge(json.loads(json.dumps(base)), over)
        self.assertEqual(merged['S'], [{'a': 1}, {'a': 1}])
        self.assertEqual(self.d.unmerge(merged, over), base)

    def test_secret_with_quote_renders_valid_json_and_roundtrips(self):
        secrets = {'K': 'ab"c\\d-efghij'}
        host = self.d.load_host()
        src = '{"k": "{{SECRET:K}}"}\n'
        out = self.d.render(src, host, secrets, json_target=True)
        self.assertEqual(json.loads(out)['k'], secrets['K'])
        self.assertEqual(self.d.unrender(out, host, secrets, json_target=True), src)


class ApplyTests(Base):
    def test_first_apply_writes_and_records_state(self):
        self.d.apply(dry=False, force=False, skip_installs=True)
        self.assertTrue(self.dest.exists())
        self.assertIn('ghp_', self.dest.read_text(encoding='utf-8'))
        self.assertIn(str(self.dest), self.state()['files'])
        self.assertTrue((self.home / '.claude' / 'hooks' / 'a.py').exists())

    def test_repo_change_overwrites_untouched_live(self):
        self.d.apply(dry=False, force=False, skip_installs=True)
        self.w(self.tmpl, self.tmpl.read_text(encoding='utf-8').replace('"nick"', '"nickname"'))
        self.d.apply(dry=False, force=False, skip_installs=True)
        self.assertIn('"nickname"', self.dest.read_text(encoding='utf-8'))

    def test_local_edit_is_kept_when_repo_unchanged(self):
        self.d.apply(dry=False, force=False, skip_installs=True)
        self.w(self.dest, '{"local": true}\n')
        self.d.apply(dry=False, force=False, skip_installs=True)
        self.assertEqual(self.dest.read_text(encoding='utf-8'), '{"local": true}\n')
        self.assertFalse((self.repo / 'ALERT.md').exists())

    def test_conflict_writes_alert_and_keeps_live(self):
        self.d.apply(dry=False, force=False, skip_installs=True)
        self.w(self.dest, '{"local": true}\n')
        self.w(self.tmpl, '{"repo": true}\n')
        self.d.apply(dry=False, force=False, skip_installs=True)
        self.assertEqual(self.dest.read_text(encoding='utf-8'), '{"local": true}\n')
        self.assertIn('conflict', (self.repo / 'ALERT.md').read_text(encoding='utf-8'))

    def test_force_overwrites_conflict(self):
        self.d.apply(dry=False, force=False, skip_installs=True)
        self.w(self.dest, '{"local": true}\n')
        self.w(self.tmpl, '{"repo": true}\n')
        self.d.apply(dry=False, force=True, skip_installs=True)
        self.assertEqual(self.dest.read_text(encoding='utf-8'), '{"repo": true}\n')

    def test_missing_secret_alerts_but_other_targets_still_apply(self):
        self.w(self.cfg / 'secrets.env', '')
        self.d.apply(dry=False, force=False, skip_installs=True)
        self.assertFalse(self.dest.exists())
        self.assertTrue((self.home / '.claude' / 'hooks' / 'a.py').exists())
        self.assertIn('SECRET:GITHUB_TOKEN', (self.repo / 'ALERT.md').read_text(encoding='utf-8'))  # engram:not-a-secret

    def test_dir_removes_managed_but_not_unmanaged(self):
        self.d.apply(dry=False, force=False, skip_installs=True)
        hooks = self.home / '.claude' / 'hooks'
        (hooks / 'mine.py').write_bytes(b'x')
        (self.repo / 'dotfiles' / 'claude' / 'hooks' / 'a.py').unlink()
        self.d.apply(dry=False, force=False, skip_installs=True)
        self.assertFalse((hooks / 'a.py').exists())
        self.assertTrue((hooks / 'mine.py').exists())

    def test_state_persists_when_installs_blow_up(self):
        def boom(host, secrets):
            raise RuntimeError('boom')
        self.d.run_installs = boom
        notes = self.d.apply(dry=False, force=False, skip_installs=False)
        self.assertIn(str(self.dest), self.state()['files'])
        self.assertTrue(any('installs failed' in n for n in notes))
        # a later local edit must now be recognised, not overwritten
        self.w(self.dest, '{"local": true}\n')
        self.d.apply(dry=False, force=False, skip_installs=True)
        self.assertEqual(self.dest.read_text(encoding='utf-8'), '{"local": true}\n')

    def test_dry_run_writes_nothing(self):
        self.d.apply(dry=True, force=False, skip_installs=True)
        self.assertFalse(self.dest.exists())
        self.assertFalse((self.cfg / 'state.json').exists())

    def test_no_marker_skips(self):
        (self.repo / '.git' / 'engram-apply-dotfiles').unlink()
        self.d.apply(dry=False, force=False, skip_installs=True)
        self.assertFalse(self.dest.exists())

    def test_overlay_and_append(self):
        self.host_file.write_text(json.dumps({
            'vars': {'nick': 'office-box'},
            'overlay': {'claude/settings.json.tmpl': {'hooks': {'SessionStart': [{'cmd': 'node gmail.mjs'}]}}},
            'append': {}}), encoding='utf-8')
        self.d.apply(dry=False, force=False, skip_installs=True)
        live = json.loads(self.dest.read_text(encoding='utf-8'))
        self.assertEqual(len(live['hooks']['SessionStart']), 2)
        self.assertEqual(live['hooks']['SessionStart'][1]['cmd'], 'node gmail.mjs')


class SaveTests(Base):
    def test_save_captures_live_edit_and_strips_overlay(self):
        self.host_file.write_text(json.dumps({
            'vars': {'nick': 'office-box'},
            'overlay': {'claude/settings.json.tmpl': {'hooks': {'SessionStart': [{'cmd': 'node gmail.mjs'}]}}},
            'append': {}}), encoding='utf-8')
        self.d.apply(dry=False, force=False, skip_installs=True)
        live = json.loads(self.dest.read_text(encoding='utf-8'))
        live['model'] = 'fable'
        self.w(self.dest, json.dumps(live, indent=2) + '\n')
        (self.home / '.claude' / 'hooks' / 'gmail-x.py').write_bytes(b'nope')
        (self.home / '.claude' / 'hooks' / 'b.py').write_bytes(b'new')
        self.d.save(stage=False)
        repo_text = self.tmpl.read_text(encoding='utf-8')
        self.assertIn('"model": "fable"', repo_text)
        self.assertNotIn('gmail.mjs', repo_text)
        self.assertNotIn('ghp_', repo_text)
        self.assertIn('{{SECRET:GITHUB_TOKEN}}', repo_text)
        self.assertTrue((self.repo / 'dotfiles' / 'claude' / 'hooks' / 'b.py').exists())
        self.assertFalse((self.repo / 'dotfiles' / 'claude' / 'hooks' / 'gmail-x.py').exists())
        # after save, apply has nothing to write
        notes = self.d.apply(dry=True, force=False, skip_installs=True)
        self.assertEqual([n for n in notes if n.startswith('write ')], [])


class ScanTests(Base):
    def test_secret_scan_patterns(self):
        added = '+  "apiKey": "sk-cp-FAKEFAKEFAKEFAKEFAKEFAKEFAKEFAKE0000"\n+  "GITHUB_TOKEN": "{{SECRET:GITHUB_TOKEN}}"\n'
        self.assertEqual(self.d.scan_added_lines(added), ['quoted credential-like string'])
        self.assertEqual(self.d.scan_added_lines('+ token = ghp_abcdefghijklmnopqrstuvwxyz0123456789\n'), ['GitHub token', 'generic credential-like string'])  # engram:not-a-secret
        self.assertEqual(self.d.scan_added_lines('+ nothing here\n'), [])


class InstallPlanTests(Base):
    def test_plan_installs_lists_only_missing(self):
        self.w(self.repo / 'dotfiles' / 'marketplaces.txt', 'caveman|JuliusBrussee/caveman\nofficial|anthropics/claude-plugins-official\n')
        self.w(self.repo / 'dotfiles' / 'plugins.txt', 'caveman@caveman\nsuperpowers@official\n')
        self.w(self.repo / 'dotfiles' / 'claude' / 'mcp.json.tmpl', '{"sheets": {"type": "http", "url": "https://x"}}\n')
        pl = self.home / '.claude' / 'plugins'
        pl.mkdir(parents=True)
        self.w(pl / 'known_marketplaces.json', '{"official": {}}')
        self.w(pl / 'installed_plugins.json', '{"plugins": {"superpowers@official": []}}')
        self.w(self.home / '.claude.json', '{"mcpServers": {}}')
        cmds = self.d.plan_installs(self.d.load_host(), self.d.load_secrets(), claude='claude')
        self.assertEqual(cmds, [
            ['claude', 'plugin', 'marketplace', 'add', 'JuliusBrussee/caveman'],
            ['claude', 'plugin', 'install', 'caveman@caveman', '-s', 'user', '-y'],
            ['claude', 'mcp', 'add-json', 'sheets', '{"type": "http", "url": "https://x"}', '-s', 'user'],
        ])


if __name__ == '__main__':
    unittest.main()
