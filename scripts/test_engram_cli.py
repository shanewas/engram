#!/usr/bin/env python3
"""Hermetic test suite for Engram 2.0 CLI and Harness Manager.

All tests run in isolated temporary sandbox fixtures. Zero live directories mutated.
Standard library only, Python 3.8+.
"""
import importlib
import json
import os
import shutil
import sys
import tempfile
import unittest
from pathlib import Path

# Add scripts directory to path
SCRIPTS_DIR = Path(__file__).resolve().parent
sys.path.insert(0, str(SCRIPTS_DIR))

import harnesses
import engram_cli


class TestEngramCli(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix='engram_test_'))
        self.repo = self.tmp / 'engram'
        self.home = self.tmp / 'home'
        self.cfg = self.tmp / 'cfg'

        # Scaffold mock repository
        self.repo.mkdir(parents=True)
        (self.repo / '.git').mkdir()
        (self.repo / 'scripts').mkdir()
        (self.repo / 'dotfiles').mkdir()
        (self.repo / 'dotfiles' / 'hosts').mkdir()
        (self.repo / 'skills' / 'core-skill').mkdir(parents=True)
        (self.repo / 'skills' / 'core-skill' / 'SKILL.md').write_text('# Core Skill\n', encoding='utf-8')
        (self.repo / 'inbox').mkdir()

        self.home.mkdir(parents=True)
        self.cfg.mkdir(parents=True)

        # Mock sync-paths.conf
        (self.repo / 'scripts' / 'sync-paths.conf').write_text("index.md\nprojects\nglobal\ninbox\narchive\nvault\n", encoding='utf-8')

        # Mock secrets.env
        (self.cfg / 'secrets.env').write_text(
            "GITHUB_TOKEN=test-gh-token-12345678\n"  # engram:not-a-secret
            "AGY_MCP_AUTH=Bearer test-auth-token-12345678\n",  # engram:not-a-secret
            encoding='utf-8'
        )

        # Mock harnesses.json
        mock_harnesses = {
            "claude": {
                "name": "Claude Code",
                "binaries": ["claude"],
                "config_dir": "{{HOME}}/.claude",
                "memory_file": "{{HOME}}/.claude/CLAUDE.md",
                "memory_import": "@{{ENGRAM_HOME_FWD}}/index.md",
                "skills_dir": "{{HOME}}/.claude/skills",
                "mcp_file": "{{HOME}}/.claude.json",
                "mcp_key": "mcpServers",
                "mcp_format": "claude"
            },
            "antigravity": {
                "name": "Antigravity (agy)",
                "binaries": ["agy"],
                "config_dir": "{{HOME}}/.gemini",
                "memory_file": "{{HOME}}/.gemini/rules/engram.md",
                "skills_dir": "{{HOME}}/.gemini/config/skills",
                "mcp_file": "{{HOME}}/.gemini/config/mcp_config.json",
                "mcp_key": "mcpServers",
                "mcp_format": "antigravity"
            }
        }
        (self.repo / 'dotfiles' / 'harnesses.json').write_text(json.dumps(mock_harnesses, indent=2), encoding='utf-8')

        # Mock mcp.json.tmpl
        mock_mcp = {
            "test-server": {
                "type": "http",
                "url": "https://mcp.test.internal/v1",
                "headers": {
                    "Authorization": "{{SECRET:AGY_MCP_AUTH}}"
                }
            }
        }
        (self.repo / 'dotfiles' / 'mcp.json.tmpl').write_text(json.dumps(mock_mcp, indent=2), encoding='utf-8')

        # Set environment overrides
        os.environ['ENGRAM_HOME'] = str(self.repo)
        os.environ['DOTFILES_REPO'] = str(self.repo)
        os.environ['DOTFILES_HOME'] = str(self.home)
        os.environ['DOTFILES_CONFIG'] = str(self.cfg)

        # Reload modules under test with new environment
        self.harnesses = importlib.reload(harnesses)
        self.cli = importlib.reload(engram_cli)

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def test_collect_skills(self):
        skills = self.harnesses.collect_available_skills(self.repo)
        self.assertIn('core-skill', skills)
        self.assertTrue((skills['core-skill'] / 'SKILL.md').exists())

    def test_claude_connect_and_disconnect(self):
        hm = self.harnesses.HarnessManager(self.repo)
        notes = hm.connect('claude')
        self.assertTrue(any('Wired memory' in n for n in notes))

        # Check CLAUDE.md
        claude_md = self.home / '.claude' / 'CLAUDE.md'
        self.assertTrue(claude_md.exists())
        content = claude_md.read_text(encoding='utf-8')
        fwd = str(self.repo).replace('\\', '/')
        self.assertIn(f'@{fwd}/index.md', content)

        # Check skills deployed
        skill_dest = self.home / '.claude' / 'skills' / 'core-skill' / 'SKILL.md'
        self.assertTrue(skill_dest.exists())

        # Check MCP injected
        claude_json = self.home / '.claude.json'
        self.assertTrue(claude_json.exists())
        data = json.loads(claude_json.read_text(encoding='utf-8'))
        self.assertIn('test-server', data.get('mcpServers', {}))
        self.assertEqual(data['mcpServers']['test-server']['url'], 'https://mcp.test.internal/v1')
        self.assertEqual(data['mcpServers']['test-server']['headers']['Authorization'], 'Bearer test-auth-token-12345678')

        # Test disconnect
        d_notes = hm.disconnect('claude')
        self.assertTrue(any('Unwired memory' in n for n in d_notes))
        updated_content = claude_md.read_text(encoding='utf-8')
        self.assertNotIn(f'@{fwd}/index.md', updated_content)

    def test_antigravity_connect(self):
        hm = self.harnesses.HarnessManager(self.repo)
        notes = hm.connect('antigravity')
        self.assertTrue(any('Wired memory' in n for n in notes))

        # Check rules/engram.md
        rule_md = self.home / '.gemini' / 'rules' / 'engram.md'
        self.assertTrue(rule_md.exists())
        self.assertIn('Engram Shared Memory', rule_md.read_text(encoding='utf-8'))

        # Check skills deployed
        skill_dest = self.home / '.gemini' / 'config' / 'skills' / 'core-skill' / 'SKILL.md'
        self.assertTrue(skill_dest.exists())

        # Check MCP injected with serverUrl conversion
        mcp_cfg = self.home / '.gemini' / 'config' / 'mcp_config.json'
        self.assertTrue(mcp_cfg.exists())
        data = json.loads(mcp_cfg.read_text(encoding='utf-8'))
        server = data['mcpServers']['test-server']
        self.assertEqual(server['serverUrl'], 'https://mcp.test.internal/v1')
        self.assertNotIn('type', server)
        self.assertEqual(server['headers']['Authorization'], 'Bearer test-auth-token-12345678')

    def test_cli_remember(self):
        args = self.cli.build_parser().parse_args(['remember', 'New', 'fact', 'captured'])
        rc = self.cli.cmd_remember(args)
        self.assertEqual(rc, 0)

        # Check inbox
        inbox_files = list((self.repo / 'inbox').glob('*.md'))
        self.assertTrue(len(inbox_files) > 0)
        content = inbox_files[0].read_text(encoding='utf-8')
        self.assertIn('New fact captured', content)

    def test_cli_include_and_exclude(self):
        # Include
        inc_args = self.cli.build_parser().parse_args(['include', 'custom_folder'])
        rc = self.cli.cmd_include(inc_args)
        self.assertEqual(rc, 0)
        self.assertIn('custom_folder', self.cli.get_allowlist())

        # Exclude
        exc_args = self.cli.build_parser().parse_args(['exclude', 'custom_folder'])
        rc = self.cli.cmd_exclude(exc_args)
        self.assertEqual(rc, 0)
        self.assertNotIn('custom_folder', self.cli.get_allowlist())


if __name__ == '__main__':
    unittest.main()
