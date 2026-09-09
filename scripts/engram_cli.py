#!/usr/bin/env python3
"""Engram 2.0: Unified CLI for cross-machine memory, skills, and agent harness management.

Supported subcommands:
  engram status                 Repo sync state, uncommitted count, and connected harnesses
  engram sync [pull|push]       Pull and push memory using normative sync contract
  engram pull | push            One-way sync
  engram connect <name|--all>   Wire memory, skills, and MCP to an agent harness
  engram disconnect <name>      Unwire memory from an agent harness
  engram harnesses              List supported and detected agent harnesses
  engram skills [list|sync]     Manage central skills and fan-out to harnesses
  engram mcp [list|sync]        Manage central MCP registry and compile configs
  engram dotfiles [apply|save]  Manage harness configuration templates and drift
  engram paths                  Show synced allowlist vs tracked code paths
  engram include <path>         Add path to sync allowlist
  engram exclude <path>         Remove path from sync allowlist
  engram audit [N]              Show last N memory commits
  engram remember <text>        Quick-capture atomic fact to current month's inbox
  engram hermes [digest]        Digest VPS Hermes memory sessions into local inbox
  engram doctor [--status]      Complete system health check
  engram restore                Show disaster recovery runbook

Standard library only, Python 3.8+.
"""
import argparse
import datetime
import json
import os
import re
import shutil
import subprocess
import sys
from pathlib import Path

# Ensure UTF-8 output on Windows
if hasattr(sys.stdout, 'reconfigure'):
    sys.stdout.reconfigure(encoding='utf-8', errors='replace')

SCRIPTS_DIR = Path(__file__).resolve().parent
REPO_ROOT = Path(os.environ.get('ENGRAM_HOME') or os.environ.get('DOTFILES_REPO') or SCRIPTS_DIR.parent)
CONF_FILE = REPO_ROOT / 'scripts' / 'sync-paths.conf'
ALERT_FILE = REPO_ROOT / 'ALERT.md'
DEFAULT_SYNCED = ['index.md', 'projects', 'global', 'inbox', 'archive', 'vault']

# Import harness manager
try:
    from harnesses import HarnessManager, collect_available_skills
except ImportError:
    sys.path.insert(0, str(SCRIPTS_DIR))
    from harnesses import HarnessManager, collect_available_skills


def get_allowlist():
    """Read sync allowlist from scripts/sync-paths.conf."""
    if not CONF_FILE.exists():
        return list(DEFAULT_SYNCED)
    out = []
    with open(CONF_FILE, encoding='utf-8', errors='replace') as f:
        for line in f:
            line = line.strip()
            if line and not line.startswith('#'):
                out.append(line)
    return out if out else list(DEFAULT_SYNCED)


def run_git(args, cwd=None, capture=False):
    """Run git command safely without interactive prompts."""
    env = dict(
        os.environ,
        GIT_TERMINAL_PROMPT='0',
        GCM_INTERACTIVE='never',
    )
    cmd = ['git'] + list(args)
    res = subprocess.run(
        cmd,
        cwd=str(cwd or REPO_ROOT),
        capture_output=capture,
        text=True,
        encoding='utf-8',
        errors='replace',
        env=env,
    )
    return res.returncode, (res.stdout or '').strip(), (res.stderr or '').strip()


def run_sync_script(verb, extra_args=None):
    """Delegate to normative platform sync script (sync.ps1 on Windows, sync.sh on POSIX)."""
    extra = extra_args or []
    if os.name == 'nt':
        script = REPO_ROOT / 'scripts' / 'sync.ps1'
        cmd = ['powershell', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', str(script), verb] + extra
    else:
        script = REPO_ROOT / 'scripts' / 'sync.sh'
        cmd = ['bash', str(script), verb] + extra
    return subprocess.run(cmd, cwd=str(REPO_ROOT)).returncode


# --- Command Handlers ---

def cmd_status(args):
    """Display comprehensive repo, sync, and connected harness dashboard."""
    print(f'Engram repository: {REPO_ROOT}')
    _, branch, _ = run_git(['rev-parse', '--abbrev-ref', 'HEAD'], capture=True)
    _, last, _ = run_git(['log', '-1', '--format=%cr (%h) — %s'], capture=True)
    run_git(['fetch', '-q', 'origin'])
    _, ahead, _ = run_git(['rev-list', '--count', '@{u}..HEAD'], capture=True)
    _, behind, _ = run_git(['rev-list', '--count', 'HEAD..@{u}'], capture=True)

    allowlist = get_allowlist()
    # Check uncommitted files in allowlist
    code, porcelain, _ = run_git(['status', '--porcelain', '--'] + allowlist, capture=True)
    dirty_count = len([l for l in porcelain.splitlines() if l.strip()]) if code == 0 else 0

    print(f'  Branch:      {branch or "unknown"}')
    print(f'  Last commit: {last or "none"}')
    print(f'  Unpushed:    {ahead or "0"} commit(s) | Behind remote: {behind or "0"} commit(s)')
    print(f'  Uncommitted: {dirty_count} file(s) in allowlist')
    print(f'  Allowlist:   {" ".join(allowlist)}')

    if ALERT_FILE.exists():
        print('  ⚠️  ALERT.md is present! Run: engram doctor')

    # Harnesses overview
    print('\nConnected Harnesses:')
    hm = HarnessManager(REPO_ROOT)
    statuses = hm.status()
    for hid, info in statuses.items():
        det_box = '[x]' if info['detected'] else '[ ]'
        con_str = 'CONNECTED' if info['connected'] else 'NOT CONNECTED'
        if not info['detected']:
            con_str = 'NOT DETECTED'
        print(f'  {det_box} {info["name"]:<22} : {con_str}')
    return 0


def cmd_paths(args):
    """Show what syncs and what is tracked but not auto-synced."""
    allow = get_allowlist()
    print(f'Synced paths (in {CONF_FILE.name}):')
    for p in allow:
        print(f'  ✓ {p}')

    code, tracked, _ = run_git(['-c', 'core.quotepath=false', 'ls-files'], capture=True)
    if code == 0:
        top_dirs = sorted(set(l.strip('"').split('/')[0] for l in tracked.splitlines() if l.strip()))
        print('\nTracked in git but NOT auto-synced (require deliberate commit):')
        any_unlisted = False
        for td in top_dirs:
            if td not in allow:
                print(f'  · {td}')
                any_unlisted = True
        if not any_unlisted:
            print('  (none)')
    return 0


def cmd_include(args):
    """Add a path to the sync allowlist."""
    if not args.paths:
        print('Usage: engram include <path> [path...]')
        return 1
    allow = get_allowlist()
    added = []
    for p in args.paths:
        p_clean = p.strip().strip('/\\')
        if not p_clean or '..' in p_clean:
            print(f'  Refused: {p}')
            continue
        if p_clean in allow:
            print(f'  Already in allowlist: {p_clean}')
        else:
            allow.append(p_clean)
            added.append(p_clean)
            print(f'  + Added to allowlist: {p_clean}')
    if added:
        CONF_FILE.write_text('\n'.join(allow) + '\n', encoding='utf-8')
        print(f'Updated {CONF_FILE}. Commit this file to sync across nodes:')
        print(f'  git -C "{REPO_ROOT}" add scripts/sync-paths.conf && git commit -m "sync: include {" ".join(added)}"')
    return 0


def cmd_exclude(args):
    """Remove a path from the sync allowlist."""
    if not args.paths:
        print('Usage: engram exclude <path> [path...]')
        return 1
    allow = get_allowlist()
    removed = []
    for p in args.paths:
        p_clean = p.strip().strip('/\\')
        if p_clean in allow:
            allow.remove(p_clean)
            removed.append(p_clean)
            print(f'  - Removed from allowlist: {p_clean}')
        else:
            print(f'  Not in allowlist: {p_clean}')
    if removed:
        CONF_FILE.write_text('\n'.join(allow) + '\n', encoding='utf-8')
        print(f'Updated {CONF_FILE}. Commit this file to sync across nodes.')
    return 0


def cmd_audit(args):
    """Display last N memory changes."""
    n = args.count or 20
    allowlist = get_allowlist()
    print(f'Last {n} memory commits (who / when / what):')
    code, out, _ = run_git(['log', f'-n{n}', '--no-merges', '--format=  %C(auto)%h%Creset  %ci  %s', '--'] + allowlist, capture=True)
    if code == 0 and out:
        print(out)
    else:
        print('  No memory commits found.')
    print('\nFull diff of any change: git show <hash>')
    return 0


def cmd_remember(args):
    """Quick-capture atomic fact to this month's inbox."""
    text = ' '.join(args.text).strip()
    if not text:
        print('Usage: engram remember <fact>')
        return 1
    now = datetime.datetime.now()
    month_str = now.strftime('%Y-%m')
    date_str = now.strftime('%Y-%m-%d')
    inbox_dir = REPO_ROOT / 'inbox'
    inbox_dir.mkdir(parents=True, exist_ok=True)
    inbox_file = inbox_dir / f'{month_str}.md'
    line = f'- {date_str} — {text}\n'

    if not inbox_file.exists():
        inbox_file.write_text(f'# Inbox {month_str}\n\n', encoding='utf-8')

    with open(inbox_file, 'a', encoding='utf-8', newline='') as f:
        f.write(line)

    print(f'Captured → {inbox_file.relative_to(REPO_ROOT)}')
    print(f'  {line.strip()}')
    return 0


def cmd_connect(args):
    """Connect an agent harness (or all detected) to engram."""
    hm = HarnessManager(REPO_ROOT)
    targets = []
    if args.all:
        statuses = hm.status()
        targets = [hid for hid, s in statuses.items() if s['detected']]
        if not targets:
            print('No known agent harnesses detected on this machine.')
            print('Supported harnesses: claude, antigravity, opencode, muse, hermes')
            return 0
    elif args.name:
        targets = [args.name.lower()]
    else:
        print('Usage: engram connect <harness-name> or engram connect --all')
        return 1

    for hid in targets:
        print(f'Connecting harness: {hid}...')
        notes = hm.connect(hid, dry_run=args.dry_run)
        for n in notes:
            print(f'  {n}')
    return 0


def cmd_disconnect(args):
    """Disconnect an agent harness from engram."""
    if not args.name:
        print('Usage: engram disconnect <harness-name>')
        return 1
    hm = HarnessManager(REPO_ROOT)
    notes = hm.disconnect(args.name.lower(), dry_run=args.dry_run)
    for n in notes:
        print(f'  {n}')
    return 0


def cmd_harnesses(args):
    """List supported agent harnesses and their connection status."""
    hm = HarnessManager(REPO_ROOT)
    statuses = hm.status()
    print(f'{"Harness ID":<14} {"Name":<22} {"Detected":<12} {"Connected":<14}')
    print('-' * 64)
    for hid, info in statuses.items():
        det_str = 'Yes' if info['detected'] else 'No'
        con_str = 'Yes' if info['connected'] else 'No'
        print(f'{hid:<14} {info["name"]:<22} {det_str:<12} {con_str:<14}')
    return 0


def cmd_skills(args):
    """Manage skills and fan out to connected harnesses."""
    action = args.action or 'list'
    available = collect_available_skills(REPO_ROOT)

    if action == 'list':
        print(f'Available skills in repository ({len(available)}):')
        for name, path in sorted(available.items()):
            rel = path.relative_to(REPO_ROOT)
            print(f'  · {name:<24} ({rel})')
        return 0

    if action == 'sync':
        hm = HarnessManager(REPO_ROOT)
        statuses = hm.status()
        connected = [hid for hid, s in statuses.items() if s['detected'] and hid != 'hermes']
        if not connected:
            print('No detected agent harnesses to sync skills to.')
            return 0
        print(f'Syncing {len(available)} skills to {len(connected)} harness(es): {", ".join(connected)}...')
        for hid in connected:
            conf = hm.spec.get(hid, {})
            skills_dir_str = conf.get('skills_dir')
            if skills_dir_str:
                from harnesses import expand_path
                dest = Path(expand_path(skills_dir_str, REPO_ROOT))
                count = hm._copy_skills(dest, dry_run=args.dry_run)
                print(f'  ✓ {conf.get("name", hid)}: {count} skills synced to {dest}')
        return 0

    print(f'Unknown skills action: {action}. Use "list" or "sync".')
    return 1


def cmd_mcp(args):
    """Manage central MCP servers and compile to harness formats."""
    action = args.action or 'list'
    mcp_tmpl = REPO_ROOT / 'dotfiles' / 'mcp.json.tmpl'

    if action == 'list':
        if not mcp_tmpl.exists():
            print(f'No MCP template found at {mcp_tmpl}')
            return 1
        with open(mcp_tmpl, encoding='utf-8') as f:
            data = json.load(f)
        print(f'Central MCP servers defined in {mcp_tmpl.name} ({len(data)}):')
        for name, cfg in data.items():
            stype = cfg.get('type') or ('stdio' if 'command' in cfg else 'http')
            url = cfg.get('url') or cfg.get('serverUrl') or cfg.get('command') or ''
            dis = ' [disabled]' if cfg.get('disabled') else ''
            print(f'  · {name:<20} ({stype}) {url}{dis}')
        return 0

    if action == 'sync':
        hm = HarnessManager(REPO_ROOT)
        statuses = hm.status()
        connected = [hid for hid, s in statuses.items() if s['detected'] and hid != 'hermes']
        print(f'Syncing central MCPs to {len(connected)} harness(es)...')
        for hid in connected:
            conf = hm.spec.get(hid, {})
            mcp_file_str = conf.get('mcp_file')
            if mcp_file_str:
                from harnesses import expand_path
                dest = Path(expand_path(mcp_file_str, REPO_ROOT))
                key = conf.get('mcp_key', 'mcpServers')
                fmt = conf.get('mcp_format', 'claude')
                notes = hm._inject_mcp(dest, key, fmt, dry_run=args.dry_run)
                for n in notes:
                    print(f'  ✓ {n}')
        return 0

    print(f'Unknown mcp action: {action}. Use "list" or "sync".')
    return 1


def cmd_dotfiles(args):
    """Delegate to dotfiles.py for harness configuration templates."""
    dotfiles_py = REPO_ROOT / 'scripts' / 'dotfiles.py'
    if not dotfiles_py.exists():
        print('scripts/dotfiles.py not found.')
        return 1
    sub = args.dotfiles_args or ['doctor']
    cmd = [sys.executable, '-X', 'utf8', str(dotfiles_py)] + sub
    return subprocess.run(cmd).returncode


def cmd_hermes(args):
    """Execute Hermes activity digest into local vault inbox."""
    digest_script = REPO_ROOT / 'scripts' / 'digest-hermes.ps1'
    if not digest_script.exists():
        print(f'scripts/digest-hermes.ps1 not found.')
        return 1
    if os.name == 'nt':
        cmd = ['powershell', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', str(digest_script)]
    else:
        print('Hermes PowerShell digest is configured for Windows hosts.')
        return 0
    return subprocess.run(cmd, cwd=str(REPO_ROOT)).returncode


def cmd_doctor(args):
    """Run comprehensive health check on repo, remotes, dotfiles, and harnesses."""
    print('=== Engram Health Check ===\n')
    bad = 0

    # 1. Check Git
    code, rem, _ = run_git(['remote', 'get-url', 'origin'], capture=True)
    if code == 0 and rem:
        print(f'PASS origin remote configured: {rem}')
    else:
        print('FAIL origin remote not configured or unreachable')
        bad += 1

    # 2. Check ALERT.md
    if ALERT_FILE.exists():
        print(f'FAIL ALERT.md exists at {ALERT_FILE}')
        bad += 1
    else:
        print('PASS no ALERT.md present')

    # 3. Check Sync Allowlist
    if CONF_FILE.exists():
        print(f'PASS sync-paths.conf exists ({len(get_allowlist())} paths)')
    else:
        print('WARN sync-paths.conf missing, using defaults')

    # 4. Check Dotfiles Status
    dotfiles_py = REPO_ROOT / 'scripts' / 'dotfiles.py'
    if dotfiles_py.exists():
        print('\nChecking dotfiles integrity:')
        rc = subprocess.run([sys.executable, '-X', 'utf8', str(dotfiles_py), 'doctor']).returncode
        if rc != 0:
            bad += 1

    # 5. Check Harnesses
    print('\nChecking agent harnesses:')
    hm = HarnessManager(REPO_ROOT)
    for hid, s in hm.status().items():
        if s['detected']:
            status_str = 'CONNECTED' if s['connected'] else 'NOT CONNECTED (run engram connect)'
            mark = 'PASS' if s['connected'] else 'WARN'
            print(f'{mark} {s["name"]}: {status_str}')
        else:
            print(f'INFO {s["name"]}: not detected on this machine')

    print(f'\nHealth check complete: {"ALL CLEAR" if bad == 0 else f"{bad} issue(s) found"}.')
    return 1 if bad else 0


def cmd_restore(args):
    """Print disaster-recovery runbook."""
    runbook = REPO_ROOT / 'restore' / 'RESTORE-memory.md'
    if runbook.exists():
        print(f'Disaster-Recovery Runbook ({runbook}):\n')
        with open(runbook, encoding='utf-8') as f:
            for _ in range(30):
                line = f.readline()
                if not line:
                    break
                print(line.rstrip())
        print(f'\nFull runbook: {runbook}')
    else:
        print('restore/RESTORE-memory.md not found.')
    return 0


# --- CLI Parser ---

def build_parser():
    p = argparse.ArgumentParser(prog='engram', description='Engram 2.0: Personal memory and agent harness CLI')
    sub = p.add_subparsers(dest='command', help='Subcommand to run')

    # status
    sub.add_parser('status', help='Repo sync state and connected harnesses')

    # sync / pull / push
    s_sync = sub.add_parser('sync', help='Pull then push memory safely')
    s_sync.add_argument('args', nargs=argparse.REMAINDER, help='Additional arguments')
    sub.add_parser('pull', help='Pull memory from remote')
    sub.add_parser('push', help='Push memory to remote')

    # paths / include / exclude
    sub.add_parser('paths', help='List synced allowlist paths')
    s_inc = sub.add_parser('include', help='Add path to sync allowlist')
    s_inc.add_argument('paths', nargs='+', help='Path(s) to include')
    s_exc = sub.add_parser('exclude', help='Remove path from sync allowlist')
    s_exc.add_argument('paths', nargs='+', help='Path(s) to exclude')

    # audit / remember
    s_aud = sub.add_parser('audit', help='Show last N memory commits')
    s_aud.add_argument('count', nargs='?', type=int, default=20, help='Commit count')
    s_rem = sub.add_parser('remember', help='Quick-capture fact to current month inbox')
    s_rem.add_argument('text', nargs='+', help='Fact text')

    # connect / disconnect / harnesses
    s_con = sub.add_parser('connect', help='Connect an agent harness to engram')
    s_con.add_argument('name', nargs='?', help='Harness name (claude, antigravity, opencode, muse, hermes)')
    s_con.add_argument('--all', action='store_true', help='Connect all detected harnesses')
    s_con.add_argument('--dry-run', action='store_true', help='Preview changes without writing')

    s_dis = sub.add_parser('disconnect', help='Disconnect an agent harness from engram')
    s_dis.add_argument('name', help='Harness name')
    s_dis.add_argument('--dry-run', action='store_true', help='Preview changes without writing')

    sub.add_parser('harnesses', help='List supported and detected agent harnesses')

    # skills / mcp / dotfiles
    s_skl = sub.add_parser('skills', help='Manage central skills and distribution')
    s_skl.add_argument('action', nargs='?', choices=['list', 'sync'], default='list')
    s_skl.add_argument('--dry-run', action='store_true', help='Preview sync')

    s_mcp = sub.add_parser('mcp', help='Manage central MCP registry and compile configs')
    s_mcp.add_argument('action', nargs='?', choices=['list', 'sync'], default='list')
    s_mcp.add_argument('--dry-run', action='store_true', help='Preview sync')

    s_dot = sub.add_parser('dotfiles', help='Delegate to dotfiles.py for config templates')
    s_dot.add_argument('dotfiles_args', nargs=argparse.REMAINDER, help='apply | save | doctor')

    # hermes / doctor / restore
    s_her = sub.add_parser('hermes', help='Hermes bridge actions')
    s_her.add_argument('action', nargs='?', choices=['digest'], default='digest')

    s_doc = sub.add_parser('doctor', help='Complete system health check')
    s_doc.add_argument('--status', action='store_true', help='Plain-language summary')

    sub.add_parser('restore', help='Show disaster recovery runbook')
    return p


def main(argv=None):
    parser = build_parser()
    args = parser.parse_args(argv)

    if not args.command or args.command == 'help':
        parser.print_help()
        return 0

    dispatch = {
        'status': cmd_status,
        'sync': lambda a: run_sync_script('sync', getattr(a, 'args', [])),
        'pull': lambda a: run_sync_script('pull'),
        'push': lambda a: run_sync_script('push'),
        'paths': cmd_paths,
        'include': cmd_include,
        'exclude': cmd_exclude,
        'audit': cmd_audit,
        'remember': cmd_remember,
        'connect': cmd_connect,
        'disconnect': cmd_disconnect,
        'harnesses': cmd_harnesses,
        'skills': cmd_skills,
        'mcp': cmd_mcp,
        'dotfiles': cmd_dotfiles,
        'hermes': cmd_hermes,
        'doctor': cmd_doctor,
        'restore': cmd_restore,
    }

    handler = dispatch.get(args.command)
    if handler:
        return handler(args)
    parser.print_help()
    return 1


if __name__ == '__main__':
    sys.exit(main())
