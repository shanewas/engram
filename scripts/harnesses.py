#!/usr/bin/env python3
"""Engram 2.0: Pluggable agent harness manager.

Manages connection, memory wiring, skill distribution, and MCP injection
across Claude Code, Antigravity (agy), OpenCode, Muse, and Hermes.
Standard library only, Python 3.8+.
"""
import json
import os
import re
import shutil
import sys
from pathlib import Path

# Ensure UTF-8 output on Windows
if hasattr(sys.stdout, 'reconfigure'):
    sys.stdout.reconfigure(encoding='utf-8', errors='replace')

SCRIPTS_DIR = Path(__file__).resolve().parent
REPO_ROOT = Path(os.environ.get('ENGRAM_HOME') or os.environ.get('DOTFILES_REPO') or SCRIPTS_DIR.parent)
HOME = Path(os.environ.get('DOTFILES_HOME') or Path.home())
CFG_DIR = Path(os.environ.get('DOTFILES_CONFIG') or (HOME / '.config' / 'dotfiles'))
SECRETS_FILE = CFG_DIR / 'secrets.env'
HARNESSES_DEF = REPO_ROOT / 'dotfiles' / 'harnesses.json'
MCP_TMPL = REPO_ROOT / 'dotfiles' / 'mcp.json.tmpl'


def _wtext(p, s):
    with open(p, 'w', encoding='utf-8', newline='') as f:
        f.write(s)


def load_secrets():
    """Load KEY=VALUE secrets from secrets.env without evaluating as shell."""
    if not SECRETS_FILE.exists():
        return {}
    out = {}
    with open(SECRETS_FILE, encoding='utf-8', errors='replace') as f:
        for line in f:
            line = line.strip()
            if line and not line.startswith('#') and '=' in line:
                k, v = line.split('=', 1)
                out[k.strip()] = v.strip()
    return out


def expand_path(text, repo=None):
    """Replace path variables with real filesystem paths."""
    r = repo or REPO_ROOT
    h = str(HOME)
    r_str = str(r)
    h_fwd = h.replace('\\', '/')
    r_fwd = r_str.replace('\\', '/')
    return (
        text.replace('{{HOME}}', h)
        .replace('{{HOME_FWD}}', h_fwd)
        .replace('{{ENGRAM_HOME}}', r_str)
        .replace('{{ENGRAM_HOME_FWD}}', r_fwd)
        .replace('{{ENGRAM_DIR}}', r_fwd)
    )


def render_template(content, secrets):
    """Replace {{SECRET:NAME}} placeholders with real secrets."""
    def repl(m):
        sec_name = m.group(1)
        val = secrets.get(sec_name, '')
        return json.dumps(val)[1:-1]
    return re.sub(r'\{\{SECRET:(\w+)\}\}', repl, content)


def load_harnesses_spec():
    """Load harnesses.json specification."""
    if not HARNESSES_DEF.exists():
        return {}
    with open(HARNESSES_DEF, encoding='utf-8') as f:
        return json.load(f)


def strip_json_comments(text):
    """Strip single-line (//) and multi-line (/* */) comments from JSON string."""
    text = re.sub(r'//.*$', '', text, flags=re.MULTILINE)
    text = re.sub(r'/\*.*?\*/', '', text, flags=re.DOTALL)
    return text


def find_binary(names):
    """Check if any binary name exists on PATH or standard install locations."""
    exts = ['', '.exe', '.cmd', '.bat', '.ps1'] if os.name == 'nt' else ['']
    for name in names:
        for ext in exts:
            check_name = name + ext if not name.endswith(ext) else name
            found = shutil.which(check_name)
            if found:
                return found
            # Common Windows user-local paths
            candidates = [
                HOME / '.local' / 'bin' / check_name,
                HOME / 'AppData' / 'Local' / 'agy' / 'bin' / check_name,
                HOME / 'AppData' / 'Roaming' / 'npm' / check_name,
                HOME / 'AppData' / 'Local' / 'Programs' / check_name,
            ]
            for c in candidates:
                if c.exists():
                    return str(c)
    return None


def get_skill_source_dirs(repo=None):
    """Find skill source directories in the repository."""
    r = repo or REPO_ROOT
    dirs = []
    # 1. Canonical skills directory
    if (r / 'skills').is_dir():
        dirs.append(r / 'skills')
    # 2. Existing private instance .claude/skills
    if (r / '.claude' / 'skills').is_dir():
        dirs.append(r / '.claude' / 'skills')
    # 3. Public template plugins/engram/skills
    if (r / 'plugins' / 'engram' / 'skills').is_dir():
        dirs.append(r / 'plugins' / 'engram' / 'skills')
    # 4. Antigravity extra skills if present
    if (r / 'dotfiles' / 'antigravity' / 'skills').is_dir():
        dirs.append(r / 'dotfiles' / 'antigravity' / 'skills')
    return dirs


def collect_available_skills(repo=None):
    """Collect all unique available skills by name."""
    skills = {}
    for sdir in get_skill_source_dirs(repo):
        for item in sdir.iterdir():
            if item.is_dir() and (item / 'SKILL.md').exists():
                if item.name not in skills:
                    skills[item.name] = item
    return skills


# Muse (1.0.x) reads materialized dirs only: symlinked SKILL.md files are
# silently skipped and `muse skills install` rejects them, so deploy always
# copies content (copytree follows symlinks). Direct copies into the managed
# root load without lockfile tracking (verified 2026-09-09).
MUSE_FAT_EXCLUDES = {'__pycache__', '.git', '.DS_Store', 'Thumbs.db',
                      'node_modules', '.venv', '.gstack', 'dist', 'test', 'tests'}
MUSE_DOCS_ONLY = {'gstack'}  # repo stays runnable at ~/.claude/skills/gstack
# Plugin trees needing an MCP runtime Muse 1.0.x lacks. Matched against the
# source path, so harness/repo skills with similar names are unaffected.
MUSE_PLUGIN_PATH_EXCLUDES = ('chrome-devtools', 'chrome_devtools',
                              'mcp-server-dev', '/remember/',
                              'claude-code-setup')


def skill_frontmatter_name(skill_dir):
    """Read the frontmatter name: from SKILL.md, or None when absent."""
    try:
        with open(skill_dir / 'SKILL.md', encoding='utf-8', errors='replace') as f:
            head = f.read(2048)
    except OSError:
        return None
    m = re.search(r'^name:\s*(.+)$', head, re.MULTILINE)
    return m.group(1).strip().strip('"\'') if m else None


def installed_plugin_paths():
    """Install paths of user-installed Claude plugins (cache layout)."""
    paths = []
    try:
        with open(HOME / '.claude' / 'plugins' / 'installed_plugins.json',
                  encoding='utf-8') as f:
            plugins = json.load(f).get('plugins', {})
    except (OSError, ValueError):
        return paths
    for entries in plugins.values():
        if isinstance(entries, dict):
            entries = [entries]
        for e in entries or []:
            p = Path(e.get('installPath', '')) if isinstance(e, dict) else None
            if p and p.is_dir() and p not in paths:
                paths.append(p)
    return sorted(paths)


def polymath_knowledge_roots():
    """Locate cc-polymath knowledge roots (installed + classic layouts)."""
    roots = []
    cands = [p for p in installed_plugin_paths() if 'polymath' in p.name.lower()]
    legacy = HOME / '.claude' / 'plugins' / 'marketplaces' / 'cc-polymath'
    if legacy.is_dir():
        cands.append(legacy)
    for base in cands:
        for sk in sorted(base.rglob('skills')):
            if sk.is_dir() and '.openclaw' not in sk.parts:
                roots.append(sk)
    return roots


class HarnessManager:
    """Manages AI agent harness discovery, connection, and synchronization."""

    def __init__(self, repo_path=None):
        self.repo = Path(repo_path) if repo_path else REPO_ROOT
        self.spec = load_harnesses_spec()
        self.secrets = load_secrets()

    def detect(self, hid):
        """Check if a specific harness is installed or configured."""
        if hid not in self.spec:
            return False, 'Unknown harness'
        conf = self.spec[hid]
        if conf.get('type') == 'bridge':
            vault = Path(expand_path(conf.get('config_dir', ''), self.repo))
            digest_script = self.repo / 'scripts' / 'digest-hermes.ps1'
            detected = vault.exists() or digest_script.exists()
            return detected, 'Vault or digest script present' if detected else 'Vault not found'

        # Check binaries
        binaries = conf.get('binaries', [])
        found_bin = find_binary(binaries)
        if found_bin:
            return True, f'Binary found: {found_bin}'

        # Check config directory
        cfg_dir = Path(expand_path(conf.get('config_dir', ''), self.repo))
        if cfg_dir.exists():
            return True, f'Config directory found: {cfg_dir}'

        return False, 'Not detected'

    def status(self):
        """Return status dictionary for all supported harnesses."""
        out = {}
        for hid, conf in self.spec.items():
            detected, det_msg = self.detect(hid)
            connected, con_msg = self.is_connected(hid)
            out[hid] = {
                'name': conf.get('name', hid),
                'detected': detected,
                'detect_message': det_msg,
                'connected': connected,
                'connect_message': con_msg,
            }
        return out

    def is_connected(self, hid):
        """Check if engram memory is actively connected to this harness."""
        if hid not in self.spec:
            return False, 'Unknown harness'
        conf = self.spec[hid]

        if conf.get('type') == 'bridge':
            digest_script = self.repo / 'scripts' / 'digest-hermes.ps1'
            return digest_script.exists(), 'Bridge script present'

        mem_file_str = conf.get('memory_file')
        if not mem_file_str:
            return False, 'No memory file configured'

        mem_file = Path(expand_path(mem_file_str, self.repo))
        if not mem_file.exists():
            return False, f'Memory file not found: {mem_file}'

        content = mem_file.read_text(encoding='utf-8', errors='replace')
        fwd = str(self.repo).replace('\\', '/')
        if fwd in content or 'engram/index.md' in content:
            return True, f'Memory linked in {mem_file.name}'

        return False, f'Memory not linked in {mem_file.name}'

    def connect(self, hid, dry_run=False):
        """Connect memory, deploy skills, and inject MCP servers to a harness."""
        if hid not in self.spec:
            return [f'Error: unknown harness {hid}']

        conf = self.spec[hid]
        notes = []
        name = conf.get('name', hid)

        if conf.get('type') == 'bridge':
            notes.append(f'Connected {name}: vault bridge verified at {self.repo / "vault"}')
            return notes

        # 1. Wire Memory
        mem_file_str = conf.get('memory_file')
        if mem_file_str:
            mem_file = Path(expand_path(mem_file_str, self.repo))
            fwd = str(self.repo).replace('\\', '/')
            import_line = conf.get('memory_import')
            if not import_line:
                import_line = f'# Engram Shared Memory\nRead `{fwd}/index.md` for shared cross-machine memory.\nAppend durable facts to `{fwd}/inbox/`.\n'
            else:
                import_line = expand_path(import_line, self.repo)

            if not dry_run:
                mem_file.parent.mkdir(parents=True, exist_ok=True)
                existing = mem_file.read_text(encoding='utf-8', errors='replace') if mem_file.exists() else ''
                if fwd not in existing and 'engram/index.md' not in existing:
                    new_content = existing.rstrip() + '\n\n' + import_line.strip() + '\n'
                    _wtext(mem_file, new_content)
                    notes.append(f'Wired memory index into {mem_file}')
                else:
                    notes.append(f'Memory already wired in {mem_file}')
            else:
                notes.append(f'[dry-run] Would wire memory in {mem_file}')

        # 2. Deploy Skills
        skills_dir_str = conf.get('skills_dir')
        if skills_dir_str:
            dest_dir = Path(expand_path(skills_dir_str, self.repo))
            copied_count = self._copy_skills(dest_dir, dry_run=dry_run)
            prefix = '[dry-run] Would deploy' if dry_run else 'Deployed'
            notes.append(f'{prefix} {copied_count} skills to {dest_dir}')
            if hid == 'muse':
                extra_names, know, skipped = self._copy_muse_extras(dest_dir, dry_run=dry_run)
                sample = ', '.join(extra_names[:12])
                if len(extra_names) > 12:
                    sample += f', ... (+{len(extra_names) - 12} more)'
                notes.append(f'{prefix} {len(extra_names)} extra skills from '
                             f'Claude/Antigravity/plugins to {dest_dir} ({sample})')
                if know:
                    notes.append(f'{prefix} {know} polymath knowledge dirs to {dest_dir}')
                if skipped:
                    notes.append(f'skipped {len(skipped)} alias dirs '
                                 f'(frontmatter name differs): {", ".join(sorted(skipped))}')

        # 3. Inject MCP Configuration
        mcp_file_str = conf.get('mcp_file')
        if mcp_file_str and MCP_TMPL.exists():
            mcp_dest = Path(expand_path(mcp_file_str, self.repo))
            mcp_key = conf.get('mcp_key', 'mcpServers')
            mcp_fmt = conf.get('mcp_format', 'claude')
            mcp_notes = self._inject_mcp(mcp_dest, mcp_key, mcp_fmt, dry_run=dry_run)
            notes.extend(mcp_notes)

        return notes

    def disconnect(self, hid, dry_run=False):
        """Disconnect memory and unwire a harness."""
        if hid not in self.spec:
            return [f'Error: unknown harness {hid}']

        conf = self.spec[hid]
        notes = []
        mem_file_str = conf.get('memory_file')
        if mem_file_str:
            mem_file = Path(expand_path(mem_file_str, self.repo))
            if mem_file.exists():
                content = mem_file.read_text(encoding='utf-8', errors='replace')
                fwd = str(self.repo).replace('\\', '/')
                lines = [l for l in content.splitlines() if fwd not in l and 'engram/index.md' not in l and '# Engram Shared Memory' not in l]
                if not dry_run:
                    _wtext(mem_file, '\n'.join(lines).strip() + '\n')
                notes.append(f'Unwired memory from {mem_file}')
        return notes

    def _copy_skills(self, dest_dir, dry_run=False):
        """Copy skills into destination directory using real directory copies."""
        available = collect_available_skills(self.repo)
        count = 0
        skip_names = {'__pycache__', '.git', '.DS_Store', 'Thumbs.db'}

        if not dry_run:
            dest_dir.mkdir(parents=True, exist_ok=True)

        for name, src_dir in available.items():
            target = dest_dir / name
            if not dry_run:
                if os.path.islink(str(target)) or target.is_symlink():
                    try:
                        target.unlink()
                    except OSError:
                        os.rmdir(str(target))
                elif target.exists():
                    shutil.rmtree(target)
                shutil.copytree(src_dir, target, ignore=shutil.ignore_patterns(*skip_names))
            count += 1
        return count

    def _deploy_muse_skill(self, dest_dir, name, src_dir):
        """Copy one skill into the Muse managed root, materializing symlinks."""
        target = dest_dir / name
        if os.path.islink(str(target)) or target.is_symlink():
            try:
                target.unlink()
            except OSError:
                os.rmdir(str(target))
        elif target.exists():
            shutil.rmtree(target)
        if name in MUSE_DOCS_ONLY:
            target.mkdir(parents=True, exist_ok=True)
            for p in sorted(src_dir.iterdir()):
                if p.is_file() and (p.suffix == '.md' or p.name.startswith('LICENSE') or p.name == 'SKILL.md'):
                    shutil.copy2(p, target / p.name)
            return
        shutil.copytree(src_dir, target, symlinks=False,
                        ignore=shutil.ignore_patterns(*MUSE_FAT_EXCLUDES))

    def _copy_muse_extras(self, dest_dir, dry_run=False):
        """Deploy sibling-harness + plugin skills Muse can't read in place.

        Precedence: repo canonical (already deployed) wins; then Claude skills,
        Antigravity skills, then Claude plugin skill trees, first name wins.
        copytree follows symlinks, so linked skills materialize. Polymath
        knowledge dirs (no SKILL.md) ride along for ../<topic>/INDEX.md refs.
        """
        have = set(collect_available_skills(self.repo))
        cands = []
        for hid in ('claude', 'antigravity'):
            sdir = self.spec.get(hid, {}).get('skills_dir')
            if not sdir:
                continue
            root = Path(expand_path(sdir, self.repo))
            if root.is_dir():
                for item in sorted(root.iterdir()):
                    if item.is_dir() and (item / 'SKILL.md').exists():
                        cands.append((item.name, item))
        for base in installed_plugin_paths():
            trees = sorted(base.rglob('skills'), key=lambda p: (len(p.parts), str(p)))
            for sdir in trees:
                if not sdir.is_dir() or '.openclaw' in sdir.parts:
                    continue
                spath = str(sdir).replace('\\', '/')
                if any(x in spath for x in MUSE_PLUGIN_PATH_EXCLUDES):
                    continue
                for item in sorted(sdir.iterdir()):
                    if item.is_dir() and (item / 'SKILL.md').exists():
                        cands.append((item.name, item))
        if not dry_run:
            dest_dir.mkdir(parents=True, exist_ok=True)
        names, skipped_alias = [], []
        for name, src in cands:
            if name in have:
                continue
            fm = skill_frontmatter_name(src)
            if fm is not None and fm != name:
                skipped_alias.append(name)  # legacy alias dir, canonical name wins
                continue
            have.add(name)
            if not dry_run:
                self._deploy_muse_skill(dest_dir, name, src)
            names.append(name)
        know = 0
        for proot in polymath_knowledge_roots():
            for item in sorted(proot.iterdir()):
                if not item.is_dir() or (item / 'SKILL.md').exists():
                    continue
                if (dest_dir / item.name).exists():
                    continue
                if not dry_run:
                    shutil.copytree(item, dest_dir / item.name, symlinks=False,
                                    ignore=shutil.ignore_patterns(*MUSE_FAT_EXCLUDES))
                know += 1
        return names, know, skipped_alias

    def _inject_mcp(self, dest_file, key_name, fmt, dry_run=False):
        """Compile and safely inject MCP configuration into target JSON file."""
        notes = []
        raw_tmpl = MCP_TMPL.read_text(encoding='utf-8')
        rendered = render_template(raw_tmpl, self.secrets)

        try:
            servers = json.loads(rendered)
        except Exception as e:
            return [f'MCP parse error in template: {e}']

        # Format transformation
        compiled = {}
        for sname, scfg in servers.items():
            entry = dict(scfg)
            if fmt == 'antigravity':
                if 'url' in entry:
                    entry['serverUrl'] = entry.pop('url')
                entry.pop('type', None)
            elif fmt == 'opencode':
                if 'serverUrl' in entry:
                    entry['url'] = entry.pop('serverUrl')
                if entry.get('type') in ('http', 'sse') or ('url' in entry and 'command' not in entry):
                    entry['type'] = 'remote'
            elif fmt == 'claude':
                if 'serverUrl' in entry:
                    entry['url'] = entry.pop('serverUrl')
                if 'type' not in entry:
                    entry['type'] = 'http'
            compiled[sname] = entry

        if dry_run:
            notes.append(f'[dry-run] Would inject {len(compiled)} MCP servers into {dest_file}')
            return notes

        dest_file.parent.mkdir(parents=True, exist_ok=True)
        existing = {}
        if dest_file.exists():
            content = dest_file.read_text(encoding='utf-8', errors='replace')
            try:
                existing = json.loads(content)
            except Exception:
                try:
                    cleaned = strip_json_comments(content)
                    existing = json.loads(cleaned)
                except Exception as e:
                    return [f'Warning: could not parse existing JSON/JSONC in {dest_file} ({e}); skipped injection to prevent overwriting user configuration']

        if key_name not in existing or not isinstance(existing[key_name], dict):
            existing[key_name] = {}

        for sname, sdata in compiled.items():
            existing[key_name][sname] = sdata

        # Write UTF-8 with NO BOM
        _wtext(dest_file, json.dumps(existing, indent=2, ensure_ascii=False) + '\n')
        notes.append(f'Injected {len(compiled)} MCP server(s) into {dest_file} ({key_name})')
        return notes
