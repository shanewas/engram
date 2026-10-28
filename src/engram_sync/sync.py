"""Sync engine. Normative spec: docs/sync-contract.md.

Every entry point returns normally: a sync failure must never block an agent session.
"""
import datetime
import json
import os
import platform
import re
import socket
import subprocess
from pathlib import Path

from . import __version__

DEFAULT_ALLOW = ['index.md', 'projects', 'global', 'inbox', 'archive']
CONF = Path('.engram') / 'sync-paths.conf'
STALE_SECS = 300
NODES = 'nodes'  # per-node heartbeat files, always synced alongside the allowlist
HEARTBEAT_SECS = 6 * 3600
NUDGE_DAYS = 7
MARKER = 'engram:not-a-secret'
# Under pythonw (scheduled task) git would open its own console window and steal focus from fullscreen apps.
NO_WINDOW = 0x08000000 if os.name == 'nt' else 0

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
]

NOT_CONNECTED = """[engram] NOT CONNECTED: this memory repo has no 'origin' remote, so nothing
syncs to or from your other machines. Facts saved here stay on this machine
only. Fix it once: run `engram init <your-private-repo-url>`."""


def iso_now():
    return datetime.datetime.now(datetime.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')


def age_secs(ts):
    """Seconds since an iso_now() stamp; unparseable counts as infinitely old."""
    try:
        then = datetime.datetime.strptime(ts, '%Y-%m-%dT%H:%M:%SZ').replace(tzinfo=datetime.timezone.utc)
    except (TypeError, ValueError):
        return float('inf')
    return (datetime.datetime.now(datetime.timezone.utc) - then).total_seconds()


def host_name():
    raw = os.environ.get('ENGRAM_HOST') or socket.gethostname() or 'unknown-host'
    return re.sub(r'[^a-z0-9-]', '-', raw.lower())


def load_allowlist(repo):
    conf = Path(repo) / CONF
    out = []
    if conf.is_file():
        for line in conf.read_text(encoding='utf-8', errors='replace').splitlines():
            p = line.split('#', 1)[0].strip()
            if p and not os.path.isabs(p) and not p.startswith('/') and '..' not in p:
                out.append(p.rstrip('/'))
    return out or list(DEFAULT_ALLOW)


def scan_secrets(diff_text):
    added = [l for l in diff_text.splitlines()
             if l.startswith('+') and not l.startswith('+++') and MARKER not in l]
    blob = '\n'.join(added)
    return [label for rx, label in SECRET_PATTERNS if rx.search(blob)]


class Sync:
    def __init__(self, repo, out=print, refresh_skills=None, node_info=None):
        self.repo = Path(repo)
        self.git_dir = self.repo / '.git'
        self.out = out
        self.refresh_skills = refresh_skills
        self.node_info = node_info
        self.host = host_name()
        self.alert = self.repo / 'ALERT.md'
        self.lock = self.git_dir / 'engram-sync.lock'
        self.lock_ours = False
        self.lock_stamp = None

    # --- git ----------------------------------------------------------------
    def git(self, *args, remote=False):
        cmd = ['git']
        env = dict(os.environ)
        if remote:
            cmd += ['-c', 'credential.interactive=false',
                    '-c', 'http.lowSpeedLimit=1000', '-c', 'http.lowSpeedTime=15']
            env['GIT_TERMINAL_PROMPT'] = '0'
            env['GCM_INTERACTIVE'] = 'never'
            base = self.git('config', '--get', 'core.sshCommand')[1].strip() or 'ssh'
            env['GIT_SSH_COMMAND'] = base + ' -o BatchMode=yes -o ConnectTimeout=10'
        r = subprocess.run(cmd + list(args), cwd=str(self.repo), env=env,
                           stdin=subprocess.DEVNULL, capture_output=True,
                           encoding='utf-8', errors='replace', creationflags=NO_WINDOW)
        return r.returncode, (r.stdout or '') + (r.stderr or '')

    # --- state / lock -------------------------------------------------------
    def set_state(self, ok, reason=''):
        line = ('ok %s' % iso_now()) if ok else ('err %s %s' % (iso_now(), reason))
        try:
            (self.git_dir / 'engram-state').write_text(line + '\n', encoding='utf-8')
        except OSError as e:
            self.out('[engram] could not write sync state: %s' % e)

    def acquire_lock(self):
        stamp = '%d %s\n' % (os.getpid(), iso_now())
        try:
            fd = os.open(str(self.lock), os.O_CREAT | os.O_EXCL | os.O_WRONLY)
        except FileExistsError:
            try:
                age = age_secs(self.lock.read_text(encoding='utf-8').split()[1])
                if age == float('inf'):
                    raise ValueError('unparseable lock stamp')
            except (OSError, IndexError, ValueError):
                try:
                    age = datetime.datetime.now(datetime.timezone.utc).timestamp() - self.lock.stat().st_mtime
                except OSError:
                    age = STALE_SECS + 1
            if age <= STALE_SECS:
                return False
            tmp = self.lock.with_name('engram-sync.lock.%d' % os.getpid())
            tmp.write_text(stamp, encoding='utf-8')
            os.replace(str(tmp), str(self.lock))
            self.lock_ours = True
            self.lock_stamp = stamp
            return True
        with os.fdopen(fd, 'w', encoding='utf-8') as f:
            f.write(stamp)
        self.lock_ours = True
        self.lock_stamp = stamp
        return True

    def release_lock(self):
        if self.lock_ours:
            try:
                if self.lock.read_text(encoding='utf-8') == self.lock_stamp:
                    self.lock.unlink()
            except OSError:
                pass
            self.lock_ours = False
            self.lock_stamp = None

    def self_heal_rebase(self):
        if (self.git_dir / 'rebase-merge').exists() or (self.git_dir / 'rebase-apply').exists():
            self.git('rebase', '--abort')

    # --- outcomes -----------------------------------------------------------
    def print_alert(self):
        if self.alert.is_file():
            self.out(self.alert.read_text(encoding='utf-8', errors='replace').rstrip('\n'))

    def clear_alert(self):
        if self.alert.exists():
            self.alert.unlink()

    def report_offline(self, output):
        first = next((l for l in output.splitlines() if l.strip()), '')
        self.out('[engram] memory did not sync (offline?): %s' % first)

    def escalate(self, reason):
        branch = 'conflict/%s' % self.host
        rc, out = self.git('push', '--force', 'origin', 'HEAD:' + branch, remote=True)
        if rc == 0:
            head = ("**Your memory could not sync — but nothing is lost.** This machine's\n"
                    'changes are parked safely on the hub. To fix it, open your agent and\n'
                    'say: "consolidate memory".\n')
            tail = ('This node has commit(s) that could not be merged into origin/main.\n'
                    'They are safe: force-pushed to the scratch branch `%s` on origin.\n\n'
                    'Action required: run the consolidate skill to merge `%s` into main, '
                    'then delete the branch.\n' % (branch, branch))
        else:
            head = ('**Your memory could not sync, and parking the changes on the hub also\n'
                    'failed — they exist only on this machine right now.** Nothing is\n'
                    'deleted. Check your internet connection / git login, then re-run sync.\n')
            tail = ('This node has commit(s) that could not be merged into origin/main, AND\n'
                    'the fallback push to `%s` also failed:\n\n```\n%s\n```\n\n'
                    'These commits currently exist ONLY on this node. Check connectivity/auth '
                    'and re-run sync.\n' % (branch, out.strip()))
        self.alert.write_text(
            '# Engram sync ALERT\n\n%s\nDetails (for the fix):\n\n- node: %s\n- time: %s\n- reason: %s\n\n%s'
            % (head, self.host, iso_now(), reason, tail), encoding='utf-8')
        self.set_state(False, reason)

    def write_secret_alert(self, labels):
        self.alert.write_text(
            '# Engram sync ALERT\n\n'
            '**Upload stopped: something that looks like a password or key was found\n'
            'in your changes.** Nothing was uploaded and nothing is lost — the change\n'
            'is still in your files, just not synced yet.\n\n'
            'Details (for the fix):\n\n- node: %s\n- time: %s\n'
            '- reason: secret scan matched staged changes; commit refused\n\n'
            'Patterns matched:\n%s\n\n'
            'The change was NOT committed and remains unstaged in your working tree.\n'
            'To fix, open the file and either:\n\n'
            '- remove the secret (real secrets never belong in memory), or\n'
            '- if the line is a false alarm (e.g. already-redacted text), append\n'
            '  `<!-- engram:not-a-secret -->` to that exact line.\n\n'
            'Then re-run: engram sync push.\n'
            'Never work around this scan by committing manually.\n'
            % (self.host, iso_now(), '\n'.join('- ' + l for l in labels)), encoding='utf-8')

    def consolidate_nudge(self):
        log = self.repo / 'archive' / 'consolidate-log.md'
        if not log.is_file():
            return
        dates = re.findall(r'^- (\d{4}-\d{2}-\d{2})', log.read_text(encoding='utf-8', errors='replace'), re.M)
        last = None
        for d in reversed(dates):
            try:
                last = datetime.date.fromisoformat(d)
                break
            except ValueError:
                continue
        if last is None:
            return
        age = (datetime.datetime.now(datetime.timezone.utc).date() - last).days
        if age >= NUDGE_DAYS:
            self.out('[engram] Last memory consolidation was %d days ago — say "consolidate memory" when convenient.' % age)

    # --- steps --------------------------------------------------------------
    def pull_rebase(self):
        """0 = ok, 1 = conflict (aborted), 2 = network/auth failure."""
        rc, out = self.git('pull', '--rebase', '--autostash', remote=True)
        self.pull_output = out
        if rc == 0:
            return 0
        if (self.git_dir / 'rebase-merge').exists() or (self.git_dir / 'rebase-apply').exists():
            self.git('rebase', '--abort')
            return 1
        _, unmerged = self.git('diff', '--name-only', '--diff-filter=U')
        if unmerged.strip():
            return 1
        return 2

    def readonly(self):
        return (self.git_dir / 'engram-readonly').exists()

    def drain(self):
        if self.readonly():
            return
        rc, ahead = self.git('rev-list', '--count', '@{u}..HEAD')
        if rc != 0 or not ahead.strip().isdigit() or int(ahead) == 0:
            return
        rc, out = self.git('push', remote=True)
        if rc != 0:
            self.escalate('pull: draining %s unpushed commit(s) failed: %s' % (ahead.strip(), out.strip()[:200]))

    def do_pull(self):
        res = self.pull_rebase()
        if res == 0:
            if self.refresh_skills:
                self.refresh_skills(self.repo)
            self.clear_alert()
            self.set_state(True)
            self.drain()
            self.consolidate_nudge()
        elif res == 1:
            self.escalate('pull: rebase onto origin/main conflicted')
        else:
            self.set_state(False, 'pull failed: ' + self.pull_output.strip()[:200])
            self.report_offline(self.pull_output)

    def heartbeat(self):
        """Rewrite nodes/<host>.json when this node's facts change or the last one is HEARTBEAT_SECS old."""
        path = self.repo / NODES / (self.host + '.json')
        if path.parent.is_symlink() or path.is_symlink():
            raise OSError('%s is a symlink; refusing to write through it' % path)
        info = {'host': self.host, 'os': '%s %s' % (platform.system(), platform.release()), 'version': __version__}
        if self.node_info:
            info.update(self.node_info())
        try:
            old = json.loads(path.read_text(encoding='utf-8'))
        except (OSError, ValueError):
            old = {}
        if not isinstance(old, dict):
            old = {}
        synced, _ = old.pop('synced', ''), old.pop('head', None)
        if old == info and age_secs(synced) < HEARTBEAT_SECS:
            return
        info['synced'] = iso_now()
        info['head'] = self.git('rev-parse', 'HEAD')[1].strip()
        path.parent.mkdir(exist_ok=True)
        path.write_text(json.dumps(info, indent=2, sort_keys=True) + '\n', encoding='utf-8')

    def do_push(self):
        try:
            self.heartbeat()
        except OSError as e:
            self.out('[engram] node heartbeat skipped: %s' % e)
        staged = []
        for p in load_allowlist(self.repo):
            if (self.repo / p).exists():
                self.git('add', '-A', '--', p)
                staged.append(p)
        heartbeat_path = '%s/%s.json' % (NODES, self.host)
        heartbeat_abs = self.repo / heartbeat_path
        if heartbeat_abs.exists() and not heartbeat_abs.is_symlink() and not heartbeat_abs.parent.is_symlink():
            self.git('add', '-A', '--', heartbeat_path)
            staged.append(heartbeat_path)
        _, diff = self.git('diff', '--cached', '-U0', '--text', '--', *staged) if staged else (0, '')
        hits = scan_secrets(diff)
        if hits:
            self.git('reset', '-q', '--', *staged)
            self.write_secret_alert(hits)
            self.set_state(False, 'secret scan hit')
            return
        if staged and self.git('diff', '--cached', '--quiet', '--', *staged)[0] != 0:
            rc, out = self.git('commit', '-q', '-m', 'sync(%s): %s' % (self.host, iso_now()), '--', *staged)
            if rc != 0:
                self.set_state(False, 'push: commit failed: ' + out.strip()[:200])
                return
        res = self.pull_rebase()
        if res == 1:
            self.escalate('push: rebase onto origin/main conflicted')
            return
        if res == 2:
            self.set_state(False, 'push: pull failed: ' + self.pull_output.strip()[:200])
            self.report_offline(self.pull_output)
            return
        rc, out = self.git('push', remote=True)
        if rc != 0:
            self.escalate('push: git push rejected: ' + out.strip()[:200])
            return
        self.clear_alert()
        self.set_state(True)

    def run(self, mode):
        if not self.git_dir.is_dir():
            self.out('[engram] %s is not a git repo; run `engram init <repo-url>`' % self.repo)
            return
        if mode == 'push' and self.readonly():
            mode = 'pull'
        try:
            if not self.acquire_lock():
                return
        except OSError as e:
            self.out('[engram] could not take sync lock: %s' % e)
            return
        try:
            self.self_heal_rebase()
            if self.git('remote', 'get-url', 'origin')[0] != 0:
                self.out(NOT_CONNECTED)
                self.set_state(False, 'no origin remote configured')
            elif mode == 'push':
                self.do_push()
            else:
                self.do_pull()
            self.print_alert()
        except Exception as e:  # invariant 1: never raise into the agent session
            self.out('[engram] sync %s failed unexpectedly: %r' % (mode, e))
            self.set_state(False, 'unexpected: %r' % e)
        finally:
            self.release_lock()
