import argparse
import datetime
import json
import os
import re
import shutil
import subprocess
import sys
from pathlib import Path

from . import __version__, harnesses
from .sync import NODES, NO_WINDOW, Sync, age_secs, host_name, load_allowlist

SEED = Path(__file__).parent / 'seed'
TASK = 'engram-sync'  # distinct from the pre-package EngramSync task, which may carry extra actions
CRON_TAG = '# engram-sync'


def default_repo():
    return Path(os.environ.get('ENGRAM_HOME') or harnesses.home() / 'engram')


def expand_url(url):
    if re.fullmatch(r'[\w.-]+/[\w.-]+', url):
        return 'https://github.com/%s.git' % url
    return url


def say(msg):
    print(msg, flush=True)


# --- sync ---------------------------------------------------------------------------

def cmd_sync(a):
    if a.detach:
        args = [sys.executable, '-m', 'engram_sync', '--repo', str(a.repo), 'sync', a.mode]
        kw = {'stdin': subprocess.DEVNULL, 'stdout': subprocess.DEVNULL, 'stderr': subprocess.DEVNULL}
        if os.name == 'nt':
            kw['creationflags'] = 0x00000008 | 0x00000200 | 0x08000000  # DETACHED | NEW_GROUP | NO_WINDOW
        else:
            kw['start_new_session'] = True
        subprocess.Popen(args, **kw)
        return 0
    Sync(a.repo, out=say, refresh_skills=harnesses.refresh_connected, node_info=node_info).run(a.mode)
    return 0


def node_info():
    return {'agents': sorted(h for h in harnesses.registry() if harnesses.is_connected(h)),
            'scheduled': schedule_present()}


# --- schedule -----------------------------------------------------------------------

def pythonw():
    exe = Path(sys.executable)
    w = exe.with_name('pythonw.exe')
    return w if w.exists() else exe


def schedule(repo, enable):
    if os.name == 'nt':
        if enable:
            tr = '"%s" -m engram_sync --repo "%s" sync push' % (pythonw(), repo)
            r = subprocess.run(['schtasks', '/Create', '/F', '/SC', 'MINUTE', '/MO', '30', '/TN', TASK, '/TR', tr],
                               capture_output=True, encoding='utf-8', errors='replace')
        else:
            r = subprocess.run(['schtasks', '/Delete', '/F', '/TN', TASK],
                               capture_output=True, encoding='utf-8', errors='replace')
        return r.returncode == 0, (r.stdout + r.stderr).strip()
    if not shutil.which('crontab'):
        return False, 'crontab not found'
    cur = subprocess.run(['crontab', '-l'], capture_output=True, encoding='utf-8', errors='replace')
    lines = [l for l in (cur.stdout if cur.returncode == 0 else '').splitlines() if CRON_TAG not in l]
    if enable:
        lines.append('*/30 * * * * "%s" -m engram_sync --repo "%s" sync push >/dev/null 2>&1 %s'
                     % (sys.executable, repo, CRON_TAG))
    r = subprocess.run(['crontab', '-'], input='\n'.join(lines) + '\n', capture_output=True,
                       encoding='utf-8', errors='replace')
    return r.returncode == 0, (r.stdout + r.stderr).strip()


def schedule_present():
    if os.name == 'nt':
        r = subprocess.run(['schtasks', '/Query', '/TN', TASK, '/V', '/FO', 'LIST'],
                           capture_output=True, encoding='utf-8', errors='replace', creationflags=NO_WINDOW)
        return r.returncode == 0 and 'engram_sync' in r.stdout
    if not shutil.which('crontab'):
        return False
    r = subprocess.run(['crontab', '-l'], capture_output=True, encoding='utf-8', errors='replace')
    return r.returncode == 0 and CRON_TAG in r.stdout


def cmd_schedule(a):
    ok, msg = schedule(a.repo, a.state == 'on')
    say('[engram] schedule %s: %s' % (a.state, 'ok' if ok else 'FAILED ' + msg))
    return 0 if ok else 1


# --- connect ------------------------------------------------------------------------

def targets(names):
    reg = harnesses.registry()
    if names:
        bad = [n for n in names if n not in reg]
        if bad:
            raise SystemExit('unknown harness: %s (known: %s)' % (', '.join(bad), ', '.join(reg)))
        return names
    return [h for h, s in reg.items() if harnesses.detected(s)]


def cmd_connect(a):
    hids = targets(a.harness)
    if not hids:
        say('[engram] no agent harness detected; name one: %s' % ', '.join(harnesses.registry()))
        return 1
    for h in hids:
        harnesses.connect(h, a.repo, out=say, adopt=getattr(a, 'adopt', False),
                          skills_only=getattr(a, 'skills_only', False))
    return 0


def cmd_disconnect(a):
    for h in targets(a.harness) if a.harness else list(harnesses.registry()):
        harnesses.disconnect(h, a.repo, out=say)
    return 0


# --- init ---------------------------------------------------------------------------

def git(repo, *args):
    r = subprocess.run(['git'] + list(args), cwd=str(repo), capture_output=True, encoding='utf-8',
                       errors='replace', stdin=subprocess.DEVNULL, creationflags=NO_WINDOW,
                       env=dict(os.environ, GIT_TERMINAL_PROMPT='0'))
    return r.returncode, (r.stdout + r.stderr).strip()


def seed(repo):
    """Write any missing scaffold file; returns the relative paths written."""
    written = []
    for src in sorted(SEED.rglob('*')):
        if src.is_file() and '__pycache__' not in src.parts:
            rel = src.relative_to(SEED).as_posix()
            dest = repo / rel
            if not dest.exists():
                dest.parent.mkdir(parents=True, exist_ok=True)
                shutil.copyfile(src, dest)
                written.append(rel)
    return written


def cmd_init(a):
    repo, url = a.repo, expand_url(a.url)
    if not shutil.which('git'):
        say('[engram] git is not installed or not on PATH')
        return 1
    if (repo / '.git').is_dir():
        rc, origin = git(repo, 'remote', 'get-url', 'origin')
        if rc != 0:
            git(repo, 'remote', 'add', 'origin', url)
        elif origin != url:
            say('[engram] %s already syncs with %s, not %s' % (repo, origin, url))
            return 1
    elif repo.exists() and any(repo.iterdir()):
        say('[engram] %s exists and is not a git repo; pick another --repo' % repo)
        return 1
    else:
        repo.parent.mkdir(parents=True, exist_ok=True)
        rc, out = git(repo.parent, 'clone', url, str(repo))
        if rc != 0:
            say('[engram] clone failed:\n%s' % out)
            return 1
    written = seed(repo)
    if written:
        git(repo, 'add', '--', *written)
        git(repo, 'commit', '-q', '-m', 'engram: initialize memory repo')
        rc, out = git(repo, 'push', '-u', 'origin', 'HEAD')
        if rc != 0:
            say('[engram] first push failed (sync will retry):\n%s' % out)
    say('[engram] memory repo ready at %s' % repo)
    if not a.no_connect:
        a.harness = []
        cmd_connect(a)
    if not a.no_schedule:
        ok, msg = schedule(repo, True)
        say('[engram] 30-min background sync %s' % ('scheduled' if ok else 'NOT scheduled: ' + msg))
    Sync(repo, out=say, refresh_skills=harnesses.refresh_connected).run('pull')
    Sync(repo, out=say, node_info=node_info).run('push')  # registers this node in nodes/
    print_status(repo)
    return 0


# --- status / upgrade ---------------------------------------------------------------

def vtuple(v):
    return tuple(int(x) for x in re.findall(r'\d+', str(v))[:3])


def ago(secs):
    if secs == float('inf'):
        return 'never'
    for unit, n in (('d', 86400), ('h', 3600), ('m', 60)):
        if secs >= n:
            return '%d%s ago' % (secs // n, unit)
    return 'just now'


def print_status(repo):
    nodes = []
    for f in sorted((repo / NODES).glob('*.json')):
        try:
            n = json.loads(f.read_text(encoding='utf-8'))
            if isinstance(n, dict):
                nodes.append({k: re.sub(r'[\x00-\x1f\x7f]', '', v) if isinstance(v, str) else v for k, v in n.items()})
        except (OSError, ValueError) as e:
            say('[engram] unreadable %s: %s' % (f.name, e))
    if not nodes:
        say('No node has reported yet. Each node reports on its next `engram sync push`.')
        return
    newest = max(vtuple(n.get('version')) for n in nodes)
    rc, out = Sync(repo).git('ls-remote', '--heads', 'origin', 'conflict/*', remote=True)
    parked = {l.rsplit('/', 1)[-1] for l in out.splitlines() if rc == 0 and '/conflict/' in l}
    me = host_name()
    say('%-22s %-20s %-8s %-10s %-8s %s' % ('NODE', 'OS', 'VERSION', 'LAST SYNC', 'BEHIND', 'NOTES'))
    for n in nodes:
        host, age = n.get('host', '?'), age_secs(n.get('synced'))
        # heartbeat-only commits don't count: a node is behind only on memory it hasn't pulled
        head = str(n.get('head', ''))
        rc, behind = (git(repo, 'rev-list', '--count', '%s..HEAD' % head, '--', '.', ':!' + NODES)
                      if re.fullmatch(r'[0-9a-f]{40}([0-9a-f]{24})?', head) else (1, ''))
        notes = []
        if host == me:
            notes.append('this machine')
        if age > 86400:
            notes.append('STALE')
        if vtuple(n.get('version')) < newest:
            notes.append('UPDATE: engram upgrade')
        if host in parked:
            notes.append('CONFLICT: say "consolidate memory"')
        if not n.get('scheduled'):
            notes.append('no background sync')
        say('%-22s %-20s %-8s %-10s %-8s %s' % (host[:22], str(n.get('os', '?'))[:20], n.get('version', '?'),
                                               ago(age), behind if rc == 0 else '?', ', '.join(notes)))
        if n.get('agents'):
            say('%-22s agents: %s' % ('', ' '.join(n['agents'])))
    if (repo / 'ALERT.md').exists():
        say('\nThis machine has an open ALERT.md: run `engram sync pull` to see it.')


def cmd_status(a):
    Sync(a.repo, out=lambda m: None, refresh_skills=harnesses.refresh_connected).run('pull')
    print_status(a.repo)
    return 0


def cmd_upgrade(a):
    return subprocess.run([sys.executable, '-m', 'pip', 'install', '--upgrade', 'engram-sync']).returncode


# --- doctor -------------------------------------------------------------------------

def cmd_doctor(a):
    repo, fails = a.repo, []

    def check(ok, msg, warn=False):
        say('[%s] %s' % ('PASS' if ok else ('WARN' if warn else 'FAIL'), msg))
        if not ok and not warn:
            fails.append(msg)

    check(bool(shutil.which('git')), 'git on PATH')
    check((repo / '.git').is_dir(), 'memory repo at %s' % repo)
    if (repo / '.git').is_dir():
        check(git(repo, 'remote', 'get-url', 'origin')[0] == 0, 'origin remote configured')
        check(not (repo / 'ALERT.md').exists(), 'no ALERT.md (sync healthy)')
        state = repo / '.git' / 'engram-state'
        st = state.read_text(encoding='utf-8').strip() if state.exists() else 'never synced'
        check(st.startswith('ok '), 'last sync: %s' % st)
        idx = repo / 'index.md'
        n = len(idx.read_text(encoding='utf-8').splitlines()) if idx.exists() else 0
        check(0 < n <= 100, 'index.md is %d lines (1-100)' % n)
        check(True, 'allowlist: %s' % ' '.join(load_allowlist(repo)))
    check(schedule_present(), 'background sync scheduled (30 min)')
    for hid, spec in harnesses.registry().items():
        if harnesses.detected(spec):
            check(harnesses.is_connected(hid), '%s connected' % spec['name'], warn=True)
    say('engram doctor: %s' % ('healthy' if not fails else '%d check(s) failed' % len(fails)))
    return 1 if fails else 0


# --- main ---------------------------------------------------------------------------

def main(argv=None):
    p = argparse.ArgumentParser(prog='engram', description='Cross-machine memory for AI coding agents, synced through a git repo.')
    p.add_argument('--version', action='version', version='engram-sync ' + __version__)
    p.add_argument('--repo', type=Path, default=None, help='memory repo path (default: $ENGRAM_HOME or ~/engram)')
    sub = p.add_subparsers(dest='cmd', required=True)

    s = sub.add_parser('init', help='clone or create the memory repo, connect agents, schedule sync')
    s.add_argument('url', help='git URL of your private memory repo, or GitHub owner/name')
    s.add_argument('--no-connect', action='store_true')
    s.add_argument('--no-schedule', action='store_true')
    s.set_defaults(fn=cmd_init)

    s = sub.add_parser('sync', help='pull or push memory (always exits 0)')
    s.add_argument('mode', choices=['pull', 'push'])
    s.add_argument('--detach', action='store_true', help='run in a background process and return at once')
    s.set_defaults(fn=cmd_sync)

    for name, fn in (('connect', cmd_connect), ('disconnect', cmd_disconnect)):
        s = sub.add_parser(name, help='%s agent harnesses (default: all detected)' % name)
        s.add_argument('harness', nargs='*')
        if name == 'connect':
            s.add_argument('--adopt', action='store_true',
                           help='replace existing skill dirs of the same name that engram-sync did not create')
            s.add_argument('--skills-only', action='store_true',
                           help='copy skills only; leave instruction files and hooks alone (e.g. when dotfiles manage them)')
        s.set_defaults(fn=fn)

    s = sub.add_parser('schedule', help='turn the 30-min background sync on or off')
    s.add_argument('state', choices=['on', 'off'])
    s.set_defaults(fn=cmd_schedule)

    sub.add_parser('doctor', help='check repo, sync, schedule and harness health').set_defaults(fn=cmd_doctor)
    sub.add_parser('status', help='show every node: version, last sync, unseen commits, problems').set_defaults(fn=cmd_status)
    sub.add_parser('upgrade', help='upgrade engram-sync from PyPI').set_defaults(fn=cmd_upgrade)

    a = p.parse_args(argv)
    a.repo = (a.repo or default_repo()).expanduser().resolve()
    return a.fn(a)
