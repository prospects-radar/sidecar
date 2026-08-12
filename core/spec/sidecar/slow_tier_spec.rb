# frozen_string_literal: true

require_relative "../../lib/sidecar/slow_tier"
require_relative "../../lib/sidecar/project"
require_relative "../../lib/sidecar/registry"

RSpec.describe Sidecar::SlowTier do
  let(:project) { Sidecar::Project.new(root: Dir.pwd, registry: Sidecar::Registry.new) }

  def sensor(id, **overrides)
    Sidecar::Sensor.build(id, **{ name: id.to_s, command: "true", tier: :slow, kind: :computational,
                                  group: :test, scope: %w[app/**/*.rb] }.merge(overrides))
  end

  def result(id, **overrides)
    Sidecar::SensorResult.new(**{ id:, name: id.to_s, group: :test, tier: :slow, state: :green }.merge(overrides))
  end

  def change_set(files = %w[app/x.rb])
    instance_double(Sidecar::ChangeSet, files:, matching: files)
  end

  def tier(sensors, scanner: ->(_cs, s) { s.map { |sensor| result(sensor.id) } }, sample: nil)
    described_class.new(sensors:, project:, scanner:, sample: sample || -> { change_set })
  end

  around { |example| in_a_repo("app/x.rb" => "one\n") { example.run } }

  describe "#due?" do
    subject(:slow) { tier([ sensor(:full) ]) }

    def due(**overrides)
      slow.due?(**{ fast_results: [], idle_for: 120, change_set: change_set }.merge(overrides))
    end

    it "is due once the tree has been quiet and there is something to run" do
      expect(due).to be(true)
    end

    it "is not due while a run is already going" do
      expect(due(running: true)).to be(false)
    end

    # Expensive work should not start while the cheap checks are still failing:
    # the failure is the thing to fix.
    it "is not due while a fast sensor is red" do
      expect(due(fast_results: [ result(:rubocop, state: :red) ])).to be(false)
    end

    it "is not due before the fast tier has run at all" do
      expect(due(fast_results: nil)).to be(false)
    end

    it "is not due while the developer is mid-flow" do
      expect(due(idle_for: 5)).to be(false)
    end

    # Not an optimisation. Without it an idle tree is permanently due: the
    # watcher starts a run, pending hands it nothing, the empty run finishes
    # instantly, and the next tick starts another. Both ticks return before the
    # heartbeat, so the loop spins without refreshing the digest and Liveness
    # reports a perfectly healthy sidecar as DOWN sixty seconds later.
    it "is not due when nothing has moved since the last run" do
      slow.run(change_set)

      expect(due).to be(false)
    end
  end

  describe "#pending" do
    # Re-running a full suite over a subsystem nobody touched is the thrash this
    # tier exists to avoid.
    it "offers a sensor whose scope has moved since it last ran" do
      slow = tier([ sensor(:full) ])
      slow.run(change_set)
      File.write("app/x.rb", "changed\n")

      expect(slow.pending(change_set).map(&:id)).to eq(%i[full])
    end

    it "stops offering a sensor once it has covered the current tree" do
      slow = tier([ sensor(:full) ])
      slow.run(change_set)

      expect(slow.pending(change_set)).to be_empty
    end

    # Without this a sensor matching no files reads as "never run" forever,
    # because never-run (nil) and matched-nothing ([]) compare unequal — so it
    # would sit in the pending list for good, offering work there is none of.
    it "does not offer a scoped sensor that matches nothing at all" do
      empty = instance_double(Sidecar::ChangeSet, files: [], matching: [])

      expect(tier([ sensor(:full) ]).pending(empty)).to be_empty
    end

    it "always offers a sensor with no declared scope" do
      empty = instance_double(Sidecar::ChangeSet, files: [], matching: [])

      expect(tier([ sensor(:full, scope: []) ]).pending(empty).map(&:id)).to eq(%i[full])
    end
  end

  describe "#run" do
    it "returns nothing, and runs nothing, when there is nothing pending" do
      scanner = ->(_cs, _s) { raise "should not have run" }

      expect(tier([ sensor(:full) ], scanner:).run(change_set, sensors: [])).to be_empty
    end

    it "only runs the slow tier, ignoring fast sensors handed to it" do
      slow = tier([ sensor(:full), sensor(:quick, tier: :fast) ])

      expect(slow.run(change_set).map(&:id)).to eq(%i[full])
    end

    # Rather than cancel (throwing away minutes every time someone saves) or
    # pretend (reporting a verdict about code that no longer exists), a run whose
    # covered files moved underneath finishes and is marked stale.
    describe "staleness" do
      it "marks a result stale when its files moved while it ran" do
        moved = lambda do |_cs, sensors|
          File.write("app/x.rb", "moved during the run\n")
          sensors.map { |sensor| result(sensor.id) }
        end

        expect(tier([ sensor(:full) ], scanner: moved).run(change_set).first).to be_stale
      end

      it "leaves a result current when nothing moved" do
        expect(tier([ sensor(:full) ]).run(change_set).first).not_to be_stale
      end

      # A stale run still tells the next pass that this scope has been covered,
      # so it does not immediately run again.
      it "records coverage even for a stale run" do
        moved = lambda do |_cs, sensors|
          File.write("app/x.rb", "moved\n")
          sensors.map { |sensor| result(sensor.id) }
        end
        slow = tier([ sensor(:full) ], scanner: moved, sample: -> { change_set })
        slow.run(change_set)

        expect(slow.pending(change_set)).to be_empty
      end
    end
  end
end
