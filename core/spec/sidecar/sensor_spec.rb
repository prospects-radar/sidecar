# frozen_string_literal: true

require_relative "../../lib/sidecar/sensor"

RSpec.describe Sidecar::Sensor do
  def build(**overrides)
    described_class.build(
      :rubocop,
      **{ name: "Quality: RuboCop", command: "rubocop", tier: :fast,
          kind: :computational, group: :lint }.merge(overrides)
    )
  end

  describe "defaults" do
    it "runs in CI and in the sidecar loop, and not at the gate" do
      expect(build).to have_attributes(ci: true, sidecar: true, gate: false)
    end

    # Behavioural identity at cutover: the tool output core cannot parse is
    # reported rather than failed, so a merge gate is not silently hardened as a
    # side effect of moving it into a gem.
    it "treats unparseable tool output as advisory" do
      expect(build.unreadable).to eq(:advisory)
    end
  end

  describe "validation" do
    it("rejects a non-Symbol id") { expect { described_class.build("x", name: "n", command: "c", tier: :fast, kind: :computational, group: :lint) }.to raise_error(described_class::InvalidSensor, /id must be a Symbol/) }
    it("rejects an empty name")    { expect { build(name: "") }.to raise_error(described_class::InvalidSensor, /name/) }
    it("rejects an empty command") { expect { build(command: "") }.to raise_error(described_class::InvalidSensor, /command/) }
    it("rejects an unknown tier")  { expect { build(tier: :medium) }.to raise_error(described_class::InvalidSensor, /tier/) }
    it("rejects an unknown kind")  { expect { build(kind: :vibes) }.to raise_error(described_class::InvalidSensor, /kind/) }
    it("rejects a non-Array scope") { expect { build(scope: "app/**") }.to raise_error(described_class::InvalidSensor, /scope/) }
    it("rejects a non-boolean ci") { expect { build(ci: "yes") }.to raise_error(described_class::InvalidSensor, /ci/) }

    # group is closed where needs is open, because group is a vocabulary core
    # itself reasons about: it ranks severity, clusters the board and now
    # sequences the run. An unrecognised group would not sort oddly, it would
    # run last, which for a setup-ish step is wrong and invisible.
    it "rejects an unknown group and names the five that exist" do
      expect { build(group: :chores) }
        .to raise_error(described_class::InvalidSensor, /group must be one of.*setup.*lint.*test.*security.*build/m)
    end

    # needs is open: what a codebase needs is a property of that codebase. What
    # validates a resource is the project's provides-map, not this class.
    it "accepts a resource core has never heard of" do
      expect(build(needs: %i[redis oxigraph]).needs).to eq(%i[redis oxigraph])
    end

    it "still requires needs to be Symbols" do
      expect { build(needs: [ "redis" ]) }.to raise_error(described_class::InvalidSensor, /Symbols/)
    end

    # The extension point is open and supported, so there is no check that the
    # handler is one core ships — only that it can be called.
    it "accepts any handler that responds to #call" do
      handler = ->(*) { :ok }

      expect(build(handler:).handler).to eq(handler)
    end

    it "rejects a handler that cannot be called" do
      expect { build(handler: :rubocop) }
        .to raise_error(described_class::InvalidSensor, /must respond to #call/)
    end
  end

  describe "#file_scoped?" do
    it("is true when the command wants the target set") { expect(build(command: "rspec {files}")).to be_file_scoped }
    it("is false otherwise") { expect(build).not_to be_file_scoped }
  end

  describe "#whole_repo?" do
    it("is true with no declared scope") { expect(build).to be_whole_repo }
    it("is false with one") { expect(build(scope: %w[app/**/*.rb])).not_to be_whole_repo }
  end
end
