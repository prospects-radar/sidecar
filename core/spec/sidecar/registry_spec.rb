# frozen_string_literal: true

require_relative "../../lib/sidecar/registry"

RSpec.describe Sidecar::Registry do
  subject(:registry) { described_class.new }

  def defaults(**overrides)
    { name: "x", command: "true", tier: :fast, kind: :computational, group: :lint }.merge(overrides)
  end

  describe "#sensor" do
    it "registers a sensor" do
      registry.sensor(:rubocop, **defaults)

      expect(registry[:rubocop].name).to eq("x")
    end

    it "refuses a duplicate id, since two entries under one name make every lookup a coin toss" do
      registry.sensor(:rubocop, **defaults)

      expect { registry.sensor(:rubocop, **defaults) }
        .to raise_error(described_class::DuplicateSensor, /rubocop/)
    end
  end

  describe "#use" do
    let(:pack) do
      Class.new do
        def self.apply(registry)
          registry.sensor(:rubocop, name: "Quality: RuboCop", command: "rubocop",
                                    tier: :fast, kind: :computational, group: :lint)
          registry.sensor(:brakeman, name: "Security: Brakeman", command: "brakeman",
                                     tier: :fast, kind: :computational, group: :security)
        end
      end
    end

    it "applies every sensor the pack ships" do
      registry.use(pack)

      expect(registry.ids).to contain_exactly(:rubocop, :brakeman)
    end
  end

  describe "#override" do
    before { registry.sensor(:rubocop, **defaults(scope: %w[app/**/*.rb])) }

    it "replaces the named attribute and keeps the rest" do
      registry.override(:rubocop, scope: %w[packs/**/*.rb])

      expect(registry[:rubocop]).to have_attributes(scope: %w[packs/**/*.rb], command: "true")
    end

    it "keeps the sensor's position" do
      registry.sensor(:brakeman, **defaults(group: :security))
      registry.override(:rubocop, guidance: "run -a")

      expect(registry.ids).to eq(%i[rubocop brakeman])
    end

    # The failure this prevents: the scope change silently does not apply and the
    # sensor keeps running with pack defaults, which is worse than not trying.
    it "raises on an unknown id" do
      expect { registry.override(:nope, scope: []) }
        .to raise_error(described_class::UnknownSensor, /nope/)
    end
  end

  describe "#omit" do
    it "removes the sensor" do
      registry.sensor(:brakeman, **defaults)
      registry.omit(:brakeman)

      expect(registry).to be_empty
    end

    # Deliberately asymmetric with #override. The thing you wanted gone is gone,
    # so the statement is redundant rather than wrong, and raising would break a
    # dev's loop for no safety.
    it "tolerates an id the pack has since removed" do
      expect { registry.omit(:never_existed) }.not_to raise_error
    end
  end

  describe "run order" do
    before do
      registry.sensor(:full_suite, **defaults(group: :test))
      registry.sensor(:precompile, **defaults(group: :build))
      registry.sensor(:rubocop,    **defaults(group: :lint))
      registry.sensor(:db_setup,   **defaults(group: :setup))
      registry.sensor(:brakeman,   **defaults(group: :security))
      registry.sensor(:smoke,      **defaults(group: :test))
    end

    it "derives order from group, so a project appending to a pack still lands in place" do
      expect(registry.ids).to eq(%i[db_setup rubocop full_suite smoke brakeman precompile])
    end

    # A database that is not prepared fails every test sensor behind it.
    it "runs setup first" do
      expect(registry.all.first.group).to eq(:setup)
    end

    it "breaks ties inside a group by registration position" do
      expect(registry.all.select { |s| s.group == :test }.map(&:id)).to eq(%i[full_suite smoke])
    end
  end

  describe "selection" do
    before do
      registry.sensor(:a, **defaults(ci: true,  sidecar: false, gate: false, tier: :fast))
      registry.sensor(:b, **defaults(ci: false, sidecar: true,  gate: true,  tier: :fast))
      registry.sensor(:c, **defaults(ci: false, sidecar: true,  gate: false, tier: :slow))
    end

    it("selects CI steps")        { expect(registry.ci_steps.map(&:id)).to eq(%i[a]) }
    it("selects sidecar sensors") { expect(registry.sidecar_sensors.map(&:id)).to eq(%i[b c]) }
    it("selects gate sensors")    { expect(registry.gate_sensors.map(&:id)).to eq(%i[b]) }
    it("selects the fast tier")   { expect(registry.fast.map(&:id)).to eq(%i[b]) }
    it("selects the slow tier")   { expect(registry.slow.map(&:id)).to eq(%i[c]) }
  end

  describe "#declared_needs" do
    it "collects every resource any sensor names, for the project to validate" do
      registry.sensor(:a, **defaults(needs: %i[database node]))
      registry.sensor(:b, **defaults(needs: %i[node browser]))

      expect(registry.declared_needs).to contain_exactly(:database, :node, :browser)
    end
  end
end
