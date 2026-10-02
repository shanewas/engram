"""Connect agent harnesses to the memory repo: skills, instruction block, hooks."""
import json
import os
import shutil
import sys
from pathlib import Path

BEGIN = '<!-- engram-sync:begin -->'
END = '<!-- engram-sync:end -->'
OWNED = '.engram-sync'  # marker file inside every skill dir this tool copied
PKG_SKILLS = Path(__file__).parent / 'skills'


def home():
    return Path(os.environ.get('ENGRAM_USER_HOME') or Path.home())


def codex_home():
    return Path(os.environ['CODEX_HOME']) if os.environ.get('CODEX_HOME') else home() / '.codex'


def registry():
    h = home()
    return {
        'claude': {'name': 'Claude Code', 'bins': ['claude'], 'root': h / '.claude',
                   'skills': h / '.claude' / 'skills', 'memory': h / '.claude' / 'CLAUDE.md',
                   'import': True, 'settings': h / '.claude' / 'settings.json'},
        'codex': {'name': 'Codex', 'bins': ['codex'], 'root': codex_home(),
                  'skills': codex_home() / 'skills', 'memory': codex_home() / 'AGENTS.md'},
        # OpenCode reads ~/.claude/CLAUDE.md only while its own AGENTS.md is absent, so
        # creating that file would silently drop the user's Claude rules from OpenCode.
        'opencode': {'name': 'OpenCode', 'bins': ['opencode'], 'root': h / '.config' / 'opencode',
                     'skills': h / '.config' / 'opencode' / 'skills',
                     'memory': h / '.config' / 'opencode' / 'AGENTS.md', 'memory_if_exists': True},
        'antigravity': {'name': 'Antigravity', 'bins': ['agy'], 'root': h / '.gemini',
                        'skills': h / '.gemini' / 'config' / 'skills',
                        'memory': h / '.gemini' / 'rules' / 'engram.md'},
        'muse': {'name': 'Muse', 'bins': ['muse'], 'root': h / '.config' / 'muse',
                 'skills': h / '.config' / 'muse' / 'skills', 'memory': None},
    }


def detected(spec):
    return spec['root'].is_dir() or any(shutil.which(b) for b in spec['bins'])


def fwd(path):
    return str(path).replace('\\', '/')


def engram_cmd(repo, verb):
    return '"%s" -m engram_sync --repo "%s" %s' % (fwd(sys.executable), fwd(repo), verb)


# --- instruction block --------------------------------------------------------

def block(repo, with_import):
    lines = [BEGIN, '# Engram memory', '',
             'Shared cross-machine memory lives in `%s`. Read `%s/index.md` at the start of '
             'every session and follow it. Save durable facts with the `engram-remember` skill. '
             'Never store secrets there.' % (fwd(repo), fwd(repo))]
    if with_import:
        lines += ['', '@%s/index.md' % fwd(repo)]
    return '\n'.join(lines + [END]) + '\n'


def upsert_block(path, text):
    old = path.read_text(encoding='utf-8') if path.exists() else ''
    if BEGIN in old and END in old:
        head, rest = old.split(BEGIN, 1)
        new = head + text.rstrip('\n') + rest.split(END, 1)[1]
    else:
        new = old + ('\n' if old and not old.endswith('\n') else '') + ('\n' if old else '') + text
    if new != old:
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(new, encoding='utf-8')


def remove_block(path):
    if not path or not path.exists():
        return
    old = path.read_text(encoding='utf-8')
    if BEGIN not in old or END not in old:
        return
    head, rest = old.split(BEGIN, 1)
    new = (head.rstrip('\n') + '\n' + rest.split(END, 1)[1].lstrip('\n')).lstrip('\n')
    path.write_text(new, encoding='utf-8')


def has_block(path):
    return bool(path) and path.exists() and BEGIN in path.read_text(encoding='utf-8', errors='replace')


# --- skills -------------------------------------------------------------------

def skill_sources(repo):
    roots = [PKG_SKILLS, Path(repo) / 'skills']
    out = {}
    for root in roots:
        if root.is_dir():
            for d in sorted(root.iterdir()):
                if (d / 'SKILL.md').is_file():
                    out[d.name] = d
    return out


def copy_skills(repo, dest_root, out=print):
    """Copy skills as real dirs. Never replaces a dir this tool did not create."""
    dest_root.mkdir(parents=True, exist_ok=True)
    for name, src in skill_sources(repo).items():
        dest = dest_root / name
        if dest.is_symlink() or (dest.exists() and not (dest / OWNED).exists()):
            out('[engram] skip skill %s: %s exists and is not managed by engram-sync' % (name, dest))
            continue
        if dest.exists():
            shutil.rmtree(dest)
        shutil.copytree(src, dest, ignore=shutil.ignore_patterns('__pycache__'))
        (dest / OWNED).write_text('managed by engram-sync; edits here are overwritten\n', encoding='utf-8')


def remove_skills(dest_root):
    if not dest_root.is_dir():
        return
    for d in dest_root.iterdir():
        if (d / OWNED).exists():
            shutil.rmtree(d)


# --- Claude Code hooks ----------------------------------------------------------

def _is_engram_hook(cmd):
    # second clause matches the pre-package sync.sh / sync.ps1 hooks so connect replaces them
    return 'engram_sync' in cmd or ('engram' in cmd and ('sync.sh' in cmd or 'sync.ps1' in cmd))


def _load_settings(path):
    if not path.exists():
        return {}
    return json.loads(path.read_text(encoding='utf-8-sig') or '{}')


def set_claude_hooks(spec, repo, enable):
    path = spec['settings']
    settings = _load_settings(path)
    hooks = settings.setdefault('hooks', {})
    for event in ('SessionStart', 'SessionEnd'):
        groups = []
        for g in hooks.get(event, []):
            kept = [h for h in g.get('hooks', []) if not _is_engram_hook(h.get('command', ''))]
            if kept:
                groups.append(dict(g, hooks=kept))
        if enable:
            verb, timeout = ('sync pull', 20) if event == 'SessionStart' else ('sync push --detach', 10)
            groups.append({'matcher': '*', 'hooks': [
                {'type': 'command', 'command': engram_cmd(repo, verb), 'timeout': timeout}]})
        if groups:
            hooks[event] = groups
        else:
            hooks.pop(event, None)
    if not hooks:
        settings.pop('hooks', None)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(settings, indent=2, ensure_ascii=False) + '\n', encoding='utf-8')


def has_claude_hooks(spec):
    try:
        hooks = _load_settings(spec['settings']).get('hooks', {})
    except ValueError:
        return False
    return all(any('engram_sync' in h.get('command', '') for g in hooks.get(e, []) for h in g.get('hooks', []))
               for e in ('SessionStart', 'SessionEnd'))


# --- connect / disconnect ---------------------------------------------------------

def connect(hid, repo, out=print):
    spec = registry()[hid]
    copy_skills(repo, spec['skills'], out)
    mem = spec.get('memory')
    if mem and (mem.exists() or not spec.get('memory_if_exists')):
        upsert_block(mem, block(repo, spec.get('import', False)))
    if hid == 'claude':
        set_claude_hooks(spec, repo, True)
    out('[engram] connected %s' % spec['name'])


def disconnect(hid, repo, out=print):
    spec = registry()[hid]
    remove_skills(spec['skills'])
    remove_block(spec.get('memory'))
    if hid == 'claude' and spec['settings'].exists():
        set_claude_hooks(spec, repo, False)
    out('[engram] disconnected %s' % spec['name'])


def is_connected(hid):
    spec = registry()[hid]
    skills_ok = (spec['skills'] / 'engram' / OWNED).exists()
    if hid == 'claude':
        return skills_ok and has_block(spec['memory']) and has_claude_hooks(spec)
    return skills_ok


def refresh_connected(repo):
    """Re-copy skills into every connected harness; called after each successful pull."""
    for hid, spec in registry().items():
        if (spec['skills'] / 'engram' / OWNED).exists():
            copy_skills(repo, spec['skills'], out=lambda m: None)
