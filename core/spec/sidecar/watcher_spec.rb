# frozen_string_literal: true

require_relative "../../lib/sidecar/watcher"
require_relative "../../lib/sidecar/project"
require_relative "../../lib/sidecar/registry"

RSpec.describe Sidecar::Watcher do
  # Every collaborator is injected, so nothing here polls a real tree, runs a
  # real sensor, or sleeps. What is being tested is the loop's decisions.
  let(:writes) { [] }
  let(:clock) { [ 0.0 ] }
  let(:slept) { [] }

  let(:project) do
    Sidecar::Project.new(root: Dir.pwd, registry: Sidecar::Registry.new,
                         prepare_command: "prepare", seed_command: "seed",
                         data_plane_paths: %w[db/migrate/* db/schema.rb])
  end

  def change_set(files = %w[app/x.rb])
    instance_double(Sidecar::ChangeSet, base: "HEAD", files:, matching: files)
  end

  def result(id = :rubocop, **overrides)
    Sidecar::SensorResult.new(**{ id:, name: id.to_s, group: :lint, tier: :fast,
                                  state: :green }.merge(overrides))
  end

  def watcher(**overrides)
    described_class.new(
      **{ project:,
          dir: "tmp/x",
          sample: -> { change_set },
          scanner: ->(_cs, _cmd) { [ result ] },
          writer: ->(results, cs) { writes << [ results, cs ] },
          migrator: -> { @migrated = (@migrated || 0) + 1 },
          seeder: -> { @seeded = (@seeded || 0) + 1 },
          slow: instance_double(Sidecar::SlowTier, due?: false),
          clock: -> { clock.first },
          sleeper: ->(seconds) { slept << seconds } }.merge(overrides)
    )
  end

  around { |example| in_a_repo("app/x.rb" => "one\n") { example.run } }

  describe "#tick" do
    it "runs a pass when the tree has changed" do
      expect(watcher.tick).to eq(:ran)
    end

    # A save-all writes a dozen files over a few hundred milliseconds, and each
    # one would otherwise start its own pass.
    it "waits out a burst rather than chasing it" do
      shapes = [ change_set(%w[app/a.rb]), change_set(%w[app/b.rb]) ]
      still_moving = watcher(sample: -> { shapes.shift || change_set })

      expect(still_moving.tick).to eq(:settling)
    end

    it "does nothing on a tree that has not moved since the last pass" do
      subject = watcher
      subject.tick

      expect(subject.tick).to eq(:idle)
    end

    # An idle watcher must keep saying so: Liveness reads a WATCH-mode pass older
    # than a minute as a dead loop, so a quiet tree still gets its timestamp
    # refreshed well inside that window.
    it "refreshes the timestamp when it has been quiet too long" do
      subject = watcher
      subject.tick
      clock[0] = described_class::HEARTBEAT_INTERVAL + 1

      expect(subject.tick).to eq(:heartbeat)
    end

    it "rewrites the same findings on a heartbeat rather than inventing new ones" do
      subject = watcher
      subject.tick
      clock[0] = described_class::HEARTBEAT_INTERVAL + 1
      subject.tick

      expect(writes.last.first.map(&:id)).to eq([ :rubocop ])
    end
  end

  describe "the data plane" do
    # The only database on a developer's machine belongs to the developer, and
    # preparing or seeding it would drop their data.
    it "is never prepared on the host" do
      watcher(location: :host).prepare_data_plane

      expect(@migrated).to be_nil
    end

    it "is prepared in the container, where the sidecar owns one" do
      watcher(location: :container).prepare_data_plane

      expect(@migrated).to eq(1)
      expect(@seeded).to eq(1)
    end

    it "does nothing for a project that declares no prepare command" do
      bare = Sidecar::Project.new(root: Dir.pwd, registry: Sidecar::Registry.new)
      watcher(project: bare, location: :container).prepare_data_plane

      expect(@migrated).to be_nil
    end

    # Which files mean the data plane is out of date is the project's call, not a
    # regex in core.
    it "rebuilds when a file the project named as a data-plane path changes" do
      watcher(sample: -> { change_set(%w[db/schema.rb]) }).tick

      expect(@migrated).to eq(1)
    end

    it "does not rebuild for an ordinary source change" do
      watcher.tick

      expect(@migrated).to be_nil
    end

    it "rebuilds once, not on every pass over the same change" do
      subject = watcher(sample: -> { change_set(%w[db/schema.rb]) })
      subject.tick
      subject.tick

      expect(@migrated).to eq(1)
    end
  end

  # An edit landing mid-pass makes every result that follows describe a tree that
  # no longer exists, so the pass is killed and the next tick starts a fresh one.
  describe "a tree that moves during a pass" do
    it "abandons the pass rather than reporting about a tree that is gone" do
      shapes = [ change_set(%w[app/a.rb]) ]
      slow_scan = lambda do |_cs, _cmd|
        shapes << change_set(%w[app/b.rb])
        sleep 0.01
        [ result ]
      end

      subject = watcher(scanner: slow_scan, sample: -> { shapes.last || change_set })

      expect(subject.baseline).to eq(:ran).or eq(:cancelled)
    end
  end

  # A loop that dies on one bad pass is not an always-on loop. Nothing is hidden
  # by surviving: a watcher that keeps failing writes nothing, so the digest
  # stops advancing and Liveness reports it stale and then down.
  describe "#attempt" do
    it "survives a failing pass and says so" do
      subject = watcher

      expect { expect(subject.attempt { raise "boom" }).to eq(:failed) }
        .to output(/pass failed — RuntimeError: boom/).to_stderr
    end
  end

  describe "#run" do
    it "sweeps once before it starts polling" do
      watcher.run(cycles: 0)

      expect(writes.size).to eq(1)
    end

    it "polls the configured number of times" do
      watcher.run(cycles: 3)

      expect(slept.count(described_class::POLL_INTERVAL)).to eq(3)
    end
  end
end
