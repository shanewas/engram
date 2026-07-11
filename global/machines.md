# Machines

Updated: YYYY-MM-DD

<!-- One section per node. Record what a fresh session needs to know: paths, egress
     restrictions, read/write role. Example sections below — replace with yours. -->

## my-desktop (Windows) — read/write, primary

- home: `C:\Users\<you>`
- engram: `C:\Users\<you>\engram`
- egress: unrestricted

## my-vps (Linux) — read/write, always-on

- engram: `~/engram`
- egress: unrestricted (SSH or HTTPS to the git hub)
- role: always-on clone; 30-min cron push; requires `jq`

## work-laptop (Windows) — READ-ONLY node

- engram: `%USERPROFILE%\engram`
- egress: HTTPS only
- enforcement: `.git/engram-readonly` marker + push URL `DISABLED` + a repo-scoped read-only token — pull-only is structural, not a convention
- policy: no employer-confidential material into engram, ever
