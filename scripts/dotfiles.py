#!/usr/bin/env python3
"""engram dotfiles: harness config sync across machines.

  dotfiles.py apply [--dry-run] [--force] [--skip-installs]
  dotfiles.py save [--no-stage]
  dotfiles.py doctor

apply always exits 0 (runs inside a Claude SessionStart hook). Stdlib only, Python 3.8+.
"""
import argparse
import hashlib
import json
import os
import re
import shutil
import socket
import subprocess
import sys
from pathlib import Path

if hasattr(sys.stdout, 'reconfigure'):
    sys.stdout.reconfigure(encoding='utf-8', errors='replace')

REPO = Path(os.environ.get('DOTFILES_REPO') or Path(__file__).resolve().parent.parent)
DOT = REPO / 'dotfiles'
HOME = Path(os.environ.get('DOTFILES_HOME') or Path.home())
APPDATA = Path(os.environ.get('DOTFILES_APPDATA') or os.environ.get('APPDATA') or (HOME / '.config'))
CFG = Path(os.environ.get('DOTFILES_CONFIG') or (HOME / '.config' / 'dotfiles'))
STATE_FILE = CFG / 'state.json'
SECRETS_FILE = CFG / 'secrets.env'
MARKER = REPO / '.git' / 'engram-apply-dotfiles'
ALERT = REPO / 'ALERT.md'
HOST = re.sub(r'[^a-z0-9-]', '-', socket.gethostname().lower())
SKIP_NAMES = {'__pycache__', '.DS_Store', 'Thumbs.db', '.gstack', 'node_modules'}
GIT_ENV = dict(os.environ, GIT_TERMINAL_PROMPT='0', GCM_INTERACTIVE='never')

# docs/sync-contract.md section 7, plus a JSON-quoted variant the contract misses
SECRET_PATTERNS = [
    (re.compile(r'AKIA[0-9A-Z]{16}'), 'AWS access key'),
    (re.compile(r'gh[pousr]_[A-Za-z0-9]{36}'), 'GitHub token'),
    (re.compile(r'xox[baprs]-[A-Za-z0-9-]{10,}'), 'Slack token'),
    (re.compile(r'sk-[A-Za-z0-9]{20,}'), 'OpenAI-style key'),
    (re.compile(r'sk-ant-[A-Za-z0-9_-]{20,}'), 'Anthropic key'),
    (re.compile(r'AIza[0-9A-Za-z_-]{35}'), 'Google API key'),
    (re.compile(r'-----BEGIN [A-Z ]*PRIVATE KEY-----'), 'private key block'),
    (re.compile(r'eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.'), 'JWT'),
    (re.compile(r'(?i)(password|passwd|secret|token|api[_-]?key)\s*[:=]\s*\S{12,}'), 'generic credential-like string'),
    (re.compile(r'(?i)"(password|passwd|secret|token|api[_-]?key|authorization)"\s*:\s*"[^"]{12,}"'), 'quoted credential-like string'),
]


class MissingKey(Exception):
    pass


# --- small io helpers -------------------------------------------------------

def sha(b):
    return hashlib.sha256(b).hexdigest()


def rt(p):
    with open(p, encoding='utf-8', newline='') as f:
        return f.read()


def wt(p, s):
    p.parent.mkdir(parents=True, exist_ok=True)
    with open(p, 'w', encoding='utf-8', newline='') as f:
        f.write(s)


def load_json(p, default):
    return json.loads(rt(p)) if p.exists() else default


def dump_json(d):
    return json.dumps(d, indent=2, ensure_ascii=False) + '\n'


def lines(p):
    if not p.exists():
        return []
    return [l.strip() for l in rt(p).splitlines() if l.strip() and not l.strip().startswith('#')]


def load_secrets():
    out = {}
    for l in lines(SECRETS_FILE):
        if '=' in l:
            k, v = l.split('=', 1)
            out[k.strip()] = v.strip()
    return out


def load_host():
    h = load_json(DOT / 'hosts' / (HOST + '.json'), {})
    return {'vars': h.get('vars', {}), 'overlay': h.get('overlay', {}), 'append': h.get('append', {})}


def load_state():
    return load_json(STATE_FILE, {'files': {}, 'managed': {}})


def save_state(state):
    wt(STATE_FILE, dump_json(state))


def expand_dest(s):
    return Path(s.replace('{{HOME}}', str(HOME)).replace('{{APPDATA}}', str(APPDATA)))


def targets():
    out = []
    for l in lines(DOT / 'targets.conf'):
        parts = l.split('|')
        kind, src, dst = parts[0], parts[1], parts[2]
        excl = []
        for extra in parts[3:]:
            if extra.startswith('exclude='):
                excl = [g for g in extra[len('exclude='):].split(',') if g]
        out.append((kind, src, expand_dest(dst), excl))
    return out


def skip(rel):
    return any(part in SKIP_NAMES for part in rel.parts)


def excluded(rel, excl):
    return any(rel.match(g) for g in excl)


# --- templating ---------------------------------------------------------------

def home_forms():
    h = str(HOME)
    forms = [(h, '{{HOME}}')]
    if '\\' in h:
        forms = [(h.replace('\\', '\\\\'), '{{HOME_JSON}}'), (h.replace('\\', '/'), '{{HOME_FWD}}')] + forms
    return forms


def is_json(src):
    return src.endswith(('.json', '.json.tmpl', '.jsonc'))


def esc(value, json_target):
    # a secret holding " or \ must not break a JSON file
    return json.dumps(value)[1:-1] if json_target else value


def render(text, host, secrets, json_target=False):
    for literal, tag in home_forms():
        text = text.replace(tag, literal)

    def var(m):
        try:
            return esc(host['vars'][m.group(1)], json_target)
        except KeyError:
            raise MissingKey('VAR:' + m.group(1))

    def sec(m):
        try:
            return esc(secrets[m.group(1)], json_target)
        except KeyError:
            raise MissingKey('SECRET:' + m.group(1))

    text = re.sub(r'\{\{VAR:(\w+)\}\}', var, text)
    return re.sub(r'\{\{SECRET:(\w+)\}\}', sec, text)


def unrender(text, host, secrets, json_target=False):
    for k, v in sorted(secrets.items(), key=lambda kv: -len(kv[1])):
        if len(v) >= 8:
            text = text.replace(esc(v, json_target), '{{SECRET:%s}}' % k)
    for k, v in sorted(host['vars'].items(), key=lambda kv: -len(kv[1])):
        if len(v) >= 4:
            text = text.replace(esc(v, json_target), '{{VAR:%s}}' % k)
    for literal, tag in home_forms():
        text = text.replace(literal, tag)
    return text


def merge(base, over):
    if isinstance(base, dict) and isinstance(over, dict):
        for k, v in over.items():
            base[k] = merge(base[k], v) if k in base else v
        return base
    if isinstance(base, list) and isinstance(over, list):
        return base + list(over)
    return over


def unmerge(base, over):
    if isinstance(base, dict) and isinstance(over, dict):
        for k, v in over.items():
            if k in base:
                r = unmerge(base[k], v)
                if r in (None, {}, []):
                    base.pop(k)
                else:
                    base[k] = r
        return base
    if isinstance(base, list) and isinstance(over, list):
        out = list(base)
        for x in over:  # one removal per overlay item, from the end, mirrors the append
            for i in range(len(out) - 1, -1, -1):
                if out[i] == x:
                    del out[i]
                    break
        return out
    return None


def render_file(src, host, secrets):
    text = render(rt(DOT / src), host, secrets, is_json(src))
    ov = host['overlay'].get(src)
    if ov:
        text = dump_json(merge(json.loads(text), ov))
    ap = host['append'].get(src)
    if ap:
        text += ap
    return text


def capture_file(src, dest, host, secrets):
    text = rt(dest)
    ap = host['append'].get(src)
    if ap and text.endswith(ap):
        text = text[:-len(ap)]
    ov = host['overlay'].get(src)
    if ov:
        text = dump_json(unmerge(json.loads(text), ov))
    wt(DOT / src, unrender(text, host, secrets, is_json(src)))


# --- apply ----------------------------------------------------------------------

def collect(kind, src, dest, host, secrets, excl):
    if kind == 'file':
        if not (DOT / src).exists():
            return []
        return [(dest, render_file(src, host, secrets).encode('utf-8'))]
    root = DOT / src
    out = []
    if not root.exists():
        return out
    for p in sorted(root.rglob('*')):
        if p.is_dir():
            continue
        rel = p.relative_to(root)
        if skip(rel) or excluded(rel, excl):
            continue
        out.append((dest / rel, p.read_bytes()))
    return out


def decide(key, new, dest, state, force):
    nh = sha(new)
    if not dest.exists():
        return 'write', nh
    lh = sha(dest.read_bytes())
    last = state['files'].get(key)
    if lh == nh:
        return 'same', nh
    if force or last is None or lh == last:
        return 'write', nh
    if nh == last:
        return 'local-edit', nh
    return 'conflict', nh


def write_alert(alerts):
    body = ['# ALERT: dotfiles apply needs attention', '', 'host: ' + HOST, ''] + ['- ' + a for a in alerts] + [
        '', 'Resolve: run `python -X utf8 scripts/dotfiles.py save` to keep the local edit, or',
        '`python -X utf8 scripts/dotfiles.py apply --force` to take the repo version. Then delete this file.', '']
    wt(ALERT, '\n'.join(body))


def apply(dry=False, force=False, skip_installs=False):
    if not MARKER.exists():
        print('[dotfiles] no .git/engram-apply-dotfiles marker on this node, skipping')
        return []
    host, secrets = load_host(), load_secrets()
    state = load_state()
    alerts, notes = [], []
    try:
        apply_targets(host, secrets, state, dry, force, notes, alerts)
    except Exception as e:
        alerts.append('apply aborted mid-run: %r' % e)
    finally:
        # hashes of files already written must land, else the next run cannot tell a
        # local edit from a never-applied file and overwrites it
        if not dry:
            save_state(state)
    if not dry and not skip_installs:
        try:
            notes += run_installs(host, secrets)
        except Exception as e:
            alerts.append('installs failed: %r' % e)
    if not dry and alerts:
        write_alert(alerts)
    for n in notes:
        print('[dotfiles] ' + n)
    for a in alerts:
        print('[dotfiles] ALERT ' + a)
    return notes + ['ALERT ' + a for a in alerts]


def apply_targets(host, secrets, state, dry, force, notes, alerts):
    for kind, src, dest, excl in targets():
        try:
            items = collect(kind, src, dest, host, secrets, excl)
        except MissingKey as e:
            alerts.append('%s: missing %s in %s' % (src, e, SECRETS_FILE if str(e).startswith('SECRET') else 'hosts/%s.json' % HOST))
            continue
        managed = []
        for dpath, data in items:
            key = str(dpath)
            verdict, nh = decide(key, data, dpath, state, force)
            if verdict == 'write':
                notes.append('write ' + key)
                if not dry:
                    dpath.parent.mkdir(parents=True, exist_ok=True)
                    dpath.write_bytes(data)
                    state['files'][key] = nh
            elif verdict == 'same':
                state['files'][key] = nh
            elif verdict == 'local-edit':
                notes.append('local edit not saved: ' + key)
            else:
                alerts.append('conflict: %s edited locally and changed in repo' % key)
            if kind == 'dir':
                managed.append(str(dpath.relative_to(dest)))
        if kind == 'dir':
            for rel in state['managed'].get(str(dest), []):
                if rel not in managed:
                    gone = dest / rel
                    notes.append('remove ' + str(gone))
                    if not dry and gone.exists():
                        gone.unlink()
                        state['files'].pop(str(gone), None)
            state['managed'][str(dest)] = managed


# --- installs -------------------------------------------------------------------

def run(cmd, cwd=None, timeout=600):
    r = subprocess.run(cmd, cwd=cwd, capture_output=True, text=True, encoding='utf-8', errors='replace', env=GIT_ENV, timeout=timeout)
    return r.returncode, (r.stdout + r.stderr).strip()


def plan_installs(host, secrets, claude=None):
    cmds = []
    if claude:
        known = load_json(HOME / '.claude' / 'plugins' / 'known_marketplaces.json', {})
        for l in lines(DOT / 'marketplaces.txt'):
            name, source = l.split('|', 1)
            if name not in known:
                cmds.append([claude, 'plugin', 'marketplace', 'add', source])
        installed = load_json(HOME / '.claude' / 'plugins' / 'installed_plugins.json', {}).get('plugins', {})
        for spec in lines(DOT / 'plugins.txt'):
            if spec not in installed:
                cmds.append([claude, 'plugin', 'install', spec, '-s', 'user', '-y'])
        mcp = DOT / 'claude' / 'mcp.json.tmpl'
        if mcp.exists():
            have = load_json(HOME / '.claude.json', {}).get('mcpServers', {})
            for name, cfg in json.loads(render(rt(mcp), host, secrets)).items():
                if name not in have:
                    cmds.append([claude, 'mcp', 'add-json', name, json.dumps(cfg), '-s', 'user'])
    return cmds


def run_installs(host, secrets):
    notes = []
    claude = shutil.which('claude')
    if not claude:
        notes.append('claude CLI not on PATH; plugin/mcp install skipped')
    for cmd in plan_installs(host, secrets, claude):
        rc, out = run(cmd)
        notes.append('%s -> rc=%d%s' % (' '.join(cmd[1:4]), rc, '' if rc == 0 else ' ' + out[-200:]))
    notes += install_externals()
    return notes


def install_externals():
    notes = []
    skills = HOME / '.claude' / 'skills'
    for l in lines(DOT / 'externals.txt'):
        name, url, version, keep = l.split('|')
        keep = set(keep.split(','))
        d = skills / name
        if d.exists():
            have = (d / 'VERSION').read_text(encoding='utf-8').strip() if (d / 'VERSION').exists() else '?'
            if have != version:  # advisory: /gstack-upgrade owns its own migrations
                notes.append('%s at %s, repo wants %s: run /gstack-upgrade then update externals.txt' % (name, have, version))
            continue
        rc, out = run(['git', 'clone', '--depth', '1', url, str(d)])
        if rc:
            notes.append('%s clone failed: %s' % (name, out[-200:]))
            continue
        rc, out = run(['bash', './setup'], cwd=str(d))
        notes.append('%s setup rc=%d' % (name, rc))
        for sub in d.iterdir():
            if sub.name != name and (sub / 'SKILL.md').exists() and sub.name not in keep and (skills / sub.name).is_dir():
                shutil.rmtree(skills / sub.name)
                notes.append('pruned ' + sub.name)
    return notes


# --- save -----------------------------------------------------------------------

def git(*args):
    rc, out = run(['git', '-C', str(REPO)] + list(args))
    return out


def scan_added_lines(added):
    keep = [l for l in added.splitlines() if l.startswith('+') and not l.startswith('+++')
            and 'engram:not-a-secret' not in l and '{{SECRET:' not in l]
    blob = '\n'.join(keep)
    return [label for rx, label in SECRET_PATTERNS if rx.search(blob)]


def secret_scan():
    return scan_added_lines(git('diff', '--cached', '-U0', '--text'))


def save(stage=True):
    host, secrets = load_host(), load_secrets()
    state = load_state()
    for kind, src, dest, excl in targets():
        if not dest.exists():
            continue
        if kind == 'file':
            capture_file(src, dest, host, secrets)
            state['files'][str(dest)] = sha(dest.read_bytes())
            continue
        root = DOT / src
        if root.exists():
            shutil.rmtree(root)
        managed = []
        for p in sorted(dest.rglob('*')):
            if p.is_dir():
                continue
            rel = p.relative_to(dest)
            if skip(rel) or excluded(rel, excl):
                continue
            (root / rel).parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(p, root / rel)
            state['files'][str(p)] = sha(p.read_bytes())
            managed.append(str(rel))
        state['managed'][str(dest)] = managed
    repo_skills = REPO / 'plugins' / 'engram' / 'skills'
    if repo_skills.exists():
        for d in repo_skills.iterdir():
            live = HOME / '.claude' / 'skills' / d.name
            if d.is_dir() and live.is_dir():
                shutil.rmtree(d)
                shutil.copytree(live, d, ignore=shutil.ignore_patterns(*SKIP_NAMES))
    save_state(state)
    if not stage:
        return
    git('add', '--', 'dotfiles', '.claude/skills')
    hits = secret_scan()
    if hits:
        git('reset', '-q', '--', 'dotfiles', '.claude/skills')
        write_alert(['secret scan hit while staging dotfiles: ' + ', '.join(hits) + ' (nothing staged)'])
        print('[dotfiles] secret scan hit: ' + ', '.join(hits) + '. Unstaged. See ALERT.md')
        return
    print(git('diff', '--cached', '--stat'))
    print('[dotfiles] staged. Review, then: git commit -m "dotfiles(%s): <what changed>"' % HOST)


# --- doctor ---------------------------------------------------------------------

def doctor():
    checks = [
        ('marker .git/engram-apply-dotfiles', MARKER.exists()),
        ('hosts/%s.json' % HOST, (DOT / 'hosts' / (HOST + '.json')).exists()),
        ('secrets.env', SECRETS_FILE.exists()),
        ('state.json', STATE_FILE.exists()),
    ]
    refs = set()
    for kind, src, dest, excl in targets():
        if kind == 'file' and (DOT / src).exists():
            refs |= set(re.findall(r'\{\{SECRET:(\w+)\}\}', rt(DOT / src)))
    mcp = DOT / 'claude' / 'mcp.json.tmpl'
    if mcp.exists():
        refs |= set(re.findall(r'\{\{SECRET:(\w+)\}\}', rt(mcp)))
    missing = sorted(refs - set(load_secrets()))
    checks.append(('all referenced secrets present' + ('' if not missing else ' (missing: %s)' % ', '.join(missing)), not missing))
    pending = plan_installs(load_host(), load_secrets(), shutil.which('claude'))
    checks.append(('plugins/mcp installed' + ('' if not pending else ' (%d pending)' % len(pending)), not pending))
    for l in lines(DOT / 'externals.txt'):
        name, url, version, keep = l.split('|')
        vf = HOME / '.claude' / 'skills' / name / 'VERSION'
        have = vf.read_text(encoding='utf-8').strip() if vf.exists() else 'missing'
        checks.append(('%s %s' % (name, version), have == version))
    checks.append(('no ALERT.md', not ALERT.exists()))
    bad = 0
    for label, ok in checks:
        print('%s %s' % ('PASS' if ok else 'FAIL', label))
        bad += 0 if ok else 1
    return 1 if bad else 0


# --- main -----------------------------------------------------------------------

def main(argv):
    ap = argparse.ArgumentParser(prog='dotfiles.py')
    sub = ap.add_subparsers(dest='cmd', required=True)
    a = sub.add_parser('apply')
    a.add_argument('--dry-run', action='store_true')
    a.add_argument('--force', action='store_true')
    a.add_argument('--skip-installs', action='store_true')
    s = sub.add_parser('save')
    s.add_argument('--no-stage', action='store_true')
    sub.add_parser('doctor')
    ns = ap.parse_args(argv)
    if ns.cmd == 'apply':
        try:
            apply(dry=ns.dry_run, force=ns.force, skip_installs=ns.skip_installs)
        except Exception as e:  # hook invariant: never block a session
            print('[dotfiles] apply failed: %r' % e)
        return 0
    if ns.cmd == 'save':
        save(stage=not ns.no_stage)
        return 0
    return doctor()


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
