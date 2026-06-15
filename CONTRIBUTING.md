# Contributing

fanwatch is a single bash script (`fanwatch`) plus an installer and tests. Bug
reports, fixes, and tweaks for other thinkfan-managed ThinkPads are welcome.

## Dev setup

There is nothing to build. Clone, edit `fanwatch`, and run it straight from the
working tree:

```bash
./fanwatch 2
```

The installed copy under `~/.local/bin` is a snapshot; re-run
`install -Dm755 fanwatch ~/.local/bin/fanwatch` to update it, or `fanwatch
update` once it is installed (see the README).

Tools needed:

| Tool | Used for |
|------|----------|
| `bash` | the script itself |
| [`bats`](https://github.com/bats-core/bats-core) | running the tests |
| [`shellcheck`](https://www.shellcheck.net/) | linting |

On Debian/Ubuntu: `sudo apt install bats shellcheck`.

## Tests

```bash
bats tests
```

The suite lives in `tests/fanwatch.bats`. The script returns early when sourced
(the guard sits just above the `trap`/header section), so the tests source it
and call its functions directly. This puts a constraint on new code: above the
guard, only definitions and read-only discovery; anything that prints or loops
goes below it.

The tests cover the pure logic — the thinkfan off-threshold parse, the trend
arrows, the sparkline, and the temperature colouring. The culprit-attribution
functions and the main loop read live `/proc`, `top`, and `nvidia-smi`, so they
are exercised by hand on the machine rather than in CI. Add a test for new pure
logic where you can.

## Linting

```bash
shellcheck fanwatch install.sh
```

The script is shellcheck-clean and CI enforces that. If shellcheck flags
something intentional, add a `# shellcheck disable=SCxxxx` directive on the line
above it with a short reason. Don't add global ignore lists.

## CI

`.github/workflows/ci.yml` runs bats and shellcheck on every push to `main` and
on every pull request. Both jobs must pass.

## Style

Match the existing code:

- bash, `printf` over `echo`.
- Comments explain why (sensor quirks, ordering constraints, the EC's actual-vs-
  requested fan level), not what the next line does.
- Missing sensors or commands (no `nvidia-smi`, unreadable `thinkfan.yaml`) must
  reduce functionality gracefully, never crash.

## Pull requests

- Keep PRs focused; separate refactors from behavior changes.
- Update the README when flags, env vars, or output change.
- **Don't touch the `VERSION=` line in a feature or fix PR.** It is bumped once
  per release in its own commit on `main` (see Releases). Two open PRs that both
  edit it would otherwise conflict on the version, and merge order would
  silently decide the number.

## Releases

The version lives in one place: the `VERSION=` line in `fanwatch` (read, not
executed, by `install.sh` to report what an update did). It is owned by `main`,
not by PRs, so that parallel PRs never contend over the number. CI enforces this
from both sides:

- The `no-version-change` job fails any PR whose diff touches the `VERSION=`
  line.
- The `release` job runs on every push to `main` (after tests and lint pass).
  When `fanwatch` changed since the last tag, it cuts a release.

Nobody edits the `VERSION=` line by hand. The `release` job computes the next
number from the last tag and the bump level, writes it, commits, and tags
`vX.Y.Z`. The bump level comes from a label on the PR, and every PR must carry
exactly one (the `bump-label` check fails and comments otherwise):

| PR label | Effect | Use for |
|----------|--------|---------|
| `bump:patch` | patch release | bug fixes, internal changes |
| `bump:minor` | minor release | new user-facing behavior |
| `bump:major` | major release | breaking changes |
| `bump:none` | no release | docs, CI, comments — nothing users run |

`major` wins over `minor` over `patch` if several are somehow present. The
`bump-label` check re-runs when you add or change the label, so a red check goes
green once you pick one.
