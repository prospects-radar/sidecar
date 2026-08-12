# sidecar-rails

The sensor pack a Rails codebase would otherwise write identically.

Declarations only. No control flow, no IO, no process invocation, and no Railtie. This gem ships
strings naming Rails commands and never loads Rails; its own suite asserts that its `lib/` defines
no methods and shells out nowhere.

See the [repository README](../README.md) for what Sidecar is.

## Why there is no Railtie

A Railtie runs during Rails boot, and nothing in the sidecar's path goes through Rails boot. The
consequence is `require: false` in your Gemfile, which is what makes the rule enforceable instead
of merely stated: the gem can never be pulled into a Rails process.

Load it explicitly, in the one file that names the packs:

```ruby
# config/sidecar.rb
require "sidecar/rails"

Sidecar.define do
  use Sidecar::Rails::Pack
  use Sidecar::Rails::RSpecPack
end
```

## Three packs, not one

The honest contents of "the Rails pack" are a *Rails-with-RSpec-and-parallel_tests-on-importmaps*
assumption. RSpec is not Rails' default test framework, and a Rails 8 app on esbuild has no
importmap. Splitting buys that honesty for one extra `use` line, where a third gem would cost a
third gemspec, a third CI lane and a version matrix.

| Pack | Sensors |
| --- | --- |
| `Sidecar::Rails::Pack` | `rubocop`, `brakeman`, `assets_precompile`, `db_setup` |
| `Sidecar::Rails::RSpecPack` | `rspec_smoke`, `rspec_full`, `targeted_specs` |
| `Sidecar::Rails::ImportmapPack` | `importmap_audit` |

`db_setup` ships with vanilla `bin/rails db:test:prepare`. A project on `parallel_tests` overrides
it, which keeps the pack honest about what it assumes rather than shipping someone else's setup.

## What this pack will not do

It declares no `provides`. A pack asserting that your machine has node would hand half its
consumers a failing sensor where the truthful answer is **unavailable** — a sensor that cannot run
because a resource is missing, shown as such on the board rather than as a red mark against a check
nobody declined to run. What each execution location provides is a fact about your project, so your
project declares it.

## Licence

MIT. See [LICENSE](../LICENSE).
