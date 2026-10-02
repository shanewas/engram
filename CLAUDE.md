# engram-sync

Source of the `engram-sync` PyPI package (`engram` CLI). Users' memory lives in their own private repo; this repo holds only code.

## Layout

- `src/engram_sync/sync.py` — sync engine; normative spec `docs/sync-contract.md`.
- `src/engram_sync/harnesses.py` — agent registry and connect/disconnect (skills, instruction block, Claude hooks).
- `src/engram_sync/cli.py` — `init`, `sync`, `connect`, `disconnect`, `schedule`, `doctor`.
- `src/engram_sync/skills/` — skills copied into every connected agent.
- `src/engram_sync/seed/` — scaffold written into an empty memory repo by `init`. Dotfiles there must also be listed in `pyproject.toml` package-data.
- `tests/` — hermetic unittest suites (temp bare origin, temp HOME via `ENGRAM_USER_HOME`). Never point a test at a real home or repo.

## Rules

- Stdlib only, Python 3.9+. No runtime dependencies.
- `engram sync` must return normally on every path: it runs inside agent session hooks.
- Never overwrite a user file or skill dir the tool did not create (instruction text lives between `engram-sync:begin/end` markers; copied skills carry a `.engram-sync` marker).
- Changing sync behaviour means updating `docs/sync-contract.md` and `tests/test_sync.py` in the same commit.
- Test: `python -m unittest discover -s tests -t .`
- Release: bump `__version__` in `src/engram_sync/__init__.py`, tag `vX.Y.Z`; CI publishes via PyPI trusted publishing.
