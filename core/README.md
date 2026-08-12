# sidecar-core

A continuous readout of your existing quality tools, narrowed to the lines you just changed.

Every mechanism lives here: the watcher, the scan, the changed-line gate, the handlers that read
tool output, the renderers, the container stack, and the `sidecar` CLI. No Rails, no runtime
dependencies, nothing booted.

See the [repository README](../README.md) for what Sidecar is and how to configure it.

## The public surface

Small on purpose. `Scan`, `Watcher`, `SlowTier`, `Report`, `Digest`, `Dashboard`, `Liveness`,
`Stack` and `Command` are all `@api private` and reshapeable without a version bump, because
`sidecar once` execs into the runner container: a Ruby API would be correct on one side of the
container wall and lie on the other.

What is public and versioned:

| Surface | What it is |
| --- | --- |
| The artifacts | `status.json` (see `schema/status-v1.json`) and the digest, written to the configured artifact directory. |
| The exit codes | Keyed by command — see the table below. |
| `nudge`'s output | A README-shipped agent hook reads it. |
| `Sidecar.define` / `Sidecar.load(root:)` | How a project describes itself, and how a non-sidecar consumer reaches the registry. |
| `Findings` / `Outcome` / `Unreadable` | What a handler returns. |
| The gate | `files`, `empty?`, `matching`, `intersects?`, `added_lines`, `select_new`, and its two constructors. Nothing else. |
| `Sidecar.status_schema_path` | Where the shipped schema lives, for a consumer validating the artifact. |

## Exit codes

Keyed by command, because the same number means different things in different ones. This collision
is documented rather than renumbered: renaming would spend a rename budget that was deliberately
kept at zero, and `status.json`'s `schema` field is what a machine should read instead.

| Command | 0 | 1 | 2 |
| --- | --- | --- | --- |
| `once`, `run`, `gate` | clean | findings on changed lines | the run itself failed |
| `status` | fresh | stale | down |
| `start`, `stop`, `reseed` | succeeded | — | failed |
| `nudge` | always | — | — |

`gate` additionally exits 3 when it cannot see the change at all — an unresolvable base, a base
resolving to `HEAD`, or a clone too shallow to reach it. A guardrail that cannot see the change
must never report clean.

## Handlers

A handler invokes a tool and turns its output into findings. Four ship here — `PassFail`,
`Rubocop`, `Stylelint`, `TargetedSpecs` — and the extension point is open and supported: a project
names its own handler object in a sensor entry.

A handler receives a runner from core, and that runner is the only thing it is handed that can
execute anything. Cancellation lives in the runner: the fast tier dies the moment you type. A
handler reaching for `Open3` directly gets a sensor that cannot be stopped mid-run, which keeps
burning CPU on a tree that already moved. No static check catches that, so giving the handler no
other tool is the whole enforcement.

## Licence

MIT. See [LICENSE](../LICENSE).
