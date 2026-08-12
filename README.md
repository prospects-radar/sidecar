# Sidecar

A continuous readout of your existing quality tools, narrowed to the lines you just changed.

Sidecar runs the checks your project already has, keeps only the findings that sit on lines you
just touched, and renders the result as a board and a one-line digest that refresh while you type.
Whoever is editing — a person or a coding agent — learns they broke something within seconds
instead of at the next commit.

It owns no rules and no analysis of its own. Every finding comes from a tool you already installed
and could run yourself: RuboCop, Brakeman, RSpec, stylelint, whatever you declare. A check that
cannot be expressed as an existing tool invoked with arguments means the tool is missing, not that
Sidecar should grow an analysis engine.

Its isolation from your machine is constitutive rather than a tuning choice. A sidecar that slows
down the work it is watching has stopped being one.

## The two gems

| Gem | What it is |
| --- | --- |
| `sidecar-core` | Every mechanism: the watcher, the scan, the changed-line gate, the handlers, the renderers, the container stack, and the CLI. No Rails, no runtime dependencies, boots nothing. |
| `sidecar-rails` | Declarations only: sensor packs for a Rails codebase, and four defaults. No control flow, no IO, no process invocation, no Railtie. |

`sidecar-rails` depends on `sidecar-core`. A project wanting the mechanism without the pack drops
one line.

## Install

Not published to RubyGems. Consume by path in development and from git in CI:

```ruby
sidecar_local_path = "vendor/local_gems/sidecar"
if File.directory?(sidecar_local_path)
  gem "sidecar-core",  path: "#{sidecar_local_path}/core",  require: false
  gem "sidecar-rails", path: "#{sidecar_local_path}/rails", require: false
else
  gem "sidecar-core",  github: "prospects-radar/sidecar", glob: "core/*.gemspec",  branch: "main", require: false
  gem "sidecar-rails", github: "prospects-radar/sidecar", glob: "rails/*.gemspec", branch: "main", require: false
end
```

`require: false` is deliberate and load-bearing: neither gem may be pulled into a Rails process.

## Configure

A project describes itself in one Ruby value, at `config/sidecar.rb`:

```ruby
require "sidecar/rails"

Sidecar.define do
  root File.expand_path("..", __dir__)

  location :host do
    provides :browser, :node
    describe :browser, "install a browser toolchain to run this"
  end

  use Sidecar::Rails::Pack
  use Sidecar::Rails::RSpecPack

  override :db_setup, command: "bin/rails parallel:load_schema"
  omit :brakeman

  sensor :stylelint,
         name:    "Quality: stylelint",
         command: "npx stylelint",
         tier:    :fast,
         group:   :lint,
         scope:   %w[app/assets/stylesheets/**/*.css],
         needs:   [ :node ]
end
```

A project that says nothing is not a project with defaults; it is one Sidecar declines to watch,
because the alternative is guessing at an answer it would then report as fact.

## Agent integration

Add one line to your agent's session hook so every session opens with the board's current state:

```json
{ "hooks": { "SessionStart": [ { "command": "bin/sidecar nudge" } ] } }
```

`nudge` always exits 0. It is a report, never a gate.

## Founding rationale

Sidecar was commissioned by [`prospects-radar/prospects_radar`][pr] and its founding decisions live
there, in an append-only log that would have holes if they were moved:

- [ADR 0028 — the sidecar orchestrates, it does not analyse][adr28]
- [ADR 0029 — the gem owns the isolation policy][adr29]
- [ADR 0030 — a project describes itself in one Ruby value][adr30]
- [ADR 0031 — the Rails gem is a pack][adr31]
- [ADR 0032 — handlers are open, artifacts are the contract][adr32]
- [ADR 0033 — an empty target set is green][adr33]

This repository starts its own log at 0001 for decisions taken after extraction.

[pr]: https://github.com/prospects-radar/prospects_radar
[adr28]: https://github.com/prospects-radar/prospects_radar/blob/main/docs/adr/0028-sidecar-orchestrates-does-not-analyse.md
[adr29]: https://github.com/prospects-radar/prospects_radar/blob/main/docs/adr/0029-gem-owns-the-isolation-policy.md
[adr30]: https://github.com/prospects-radar/prospects_radar/blob/main/docs/adr/0030-a-project-describes-itself-in-one-ruby-value.md
[adr31]: https://github.com/prospects-radar/prospects_radar/blob/main/docs/adr/0031-the-rails-gem-is-a-pack.md
[adr32]: https://github.com/prospects-radar/prospects_radar/blob/main/docs/adr/0032-handlers-are-open-artifacts-are-the-contract.md
[adr33]: https://github.com/prospects-radar/prospects_radar/blob/main/docs/adr/0033-an-empty-target-set-is-green.md

## Licence

MIT. See [LICENSE](LICENSE).
