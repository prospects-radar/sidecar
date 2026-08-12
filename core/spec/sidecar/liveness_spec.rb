# frozen_string_literal: true

require "time"
require_relative "../../lib/sidecar/liveness"

RSpec.describe Sidecar::Liveness do
  let(:now) { Time.utc(2026, 8, 12, 12, 0, 0) }
  let(:change_set) { instance_double(Sidecar::ChangeSet, base: "HEAD", files: [ "app/x.rb" ]) }

  def status(**overrides)
    { "schema" => "sidecar.status/1",
      "generated_at" => (now - 10).iso8601,
      "mode" => "ONCE",
      "base" => "HEAD",
      "changed_files" => [ "app/x.rb" ],
      "tiers" => { "fast" => { "ran_at" => (now - 10).iso8601 } },
      "totals" => { "red" => 0, "unavailable" => 0 } }.merge(overrides)
  end

  def liveness(**overrides)
    described_class.new(status: status(**overrides), now:, change_set:)
  end

  # Freshness is judged against the working tree rather than the clock. A pass
  # from an hour ago on a tree nobody has touched is still accurate; a pass from
  # ten seconds ago is worthless if you saved a file since.
  describe "#state" do
    around { |example| in_a_repo("app/x.rb" => "one\n") { example.run } }

    it "is fresh when the tree has not moved since the pass" do
      allow(File).to receive(:mtime).with("app/x.rb").and_return(now - 60)

      expect(liveness.state).to eq(:fresh)
    end

    it "is stale when a file the pass looked at has been written since" do
      allow(File).to receive(:mtime).with("app/x.rb").and_return(now + 1)

      expect(liveness.state).to eq(:stale)
    end

    it "is stale when a file appeared that the pass never saw" do
      allow(File).to receive(:mtime).and_return(now - 60)
      allow(change_set).to receive(:files).and_return(%w[app/x.rb app/new.rb])

      expect(liveness.state).to eq(:stale)
    end

    # A file that has gone is itself a change.
    it "is stale when a file the pass looked at has disappeared" do
      allow(File).to receive(:mtime).and_raise(Errno::ENOENT)

      expect(liveness.state).to eq(:stale)
    end

    it "is down when no pass has ever run" do
      expect(described_class.new(status: nil, now:, change_set:).state).to eq(:down)
    end

    # In watch mode a tick is due every few seconds, so a minute of silence
    # means the loop is gone rather than merely idle.
    it "is down when a watch-mode pass missed its heartbeat" do
      stale = liveness("mode" => "WATCH", "generated_at" => (now - 120).iso8601)

      expect(stale.state).to eq(:down)
    end

    it "is not down for an old pass that was never a watch loop" do
      allow(File).to receive(:mtime).and_return(now - 600)

      expect(liveness("generated_at" => (now - 500).iso8601).state).to eq(:fresh)
    end
  end

  # The verdict goes in an exit code so a dead or lagging sidecar cannot
  # masquerade as a clean one.
  describe "#exit_code" do
    around { |example| in_a_repo("app/x.rb" => "one\n") { example.run } }

    it "is 0 when fresh" do
      allow(File).to receive(:mtime).and_return(now - 60)

      expect(liveness.exit_code).to eq(0)
    end

    it "is 2 when there is nothing to believe" do
      expect(described_class.new(status: nil, now:, change_set:).exit_code).to eq(2)
    end
  end

  describe "#nudge" do
    around { |example| in_a_repo("app/x.rb" => "one\n") { example.run } }
    before { allow(File).to receive(:mtime).and_return(now - 60) }

    # Silence when no pass has ever run: the developer is not using the sidecar,
    # and nagging every session would be noise.
    it "says nothing at all when no pass has ever run" do
      expect(described_class.new(status: nil, now:, change_set:).nudge).to be_nil
    end

    it "reports red sensors over freshness, since that is the actionable part" do
      expect(liveness("totals" => { "red" => 3 }).nudge).to include("3 sensor(s) red")
    end

    # A board that is green because a check never ran is not the same as passing.
    it "mentions a tool that is not installed even on a green pass" do
      expect(liveness("totals" => { "red" => 0, "unavailable" => 2 }).nudge)
        .to include("2 tool(s) not installed")
    end

    it "stays quiet about unavailable tools when there are none" do
      expect(liveness.nudge).not_to include("not installed")
    end
  end

  # The image carries its own bundle, so a host that bumped the gem runs a
  # different core against the same config until a rebuild.
  describe "#version_skew" do
    it "is silent when both sides agree" do
      expect(liveness("core" => { "version" => Sidecar::VERSION }).version_skew).to be_nil
    end

    it "names both versions when they differ" do
      expect(liveness("core" => { "version" => "0.0.1" }).version_skew)
        .to include("0.0.1").and include("rebuild")
    end

    it "is silent for an artifact written before the field existed" do
      expect(liveness.version_skew).to be_nil
    end
  end

  # A stale slow result is worth naming rather than folding into "current". It is
  # the one line that tells you a four-minute verdict is about code you have
  # already changed.
  describe "#headline" do
    around { |example| in_a_repo("app/x.rb" => "one\n") { example.run } }
    before { allow(File).to receive(:mtime).and_return(now - 60) }

    it "says the slow tier has not run rather than leaving a silent gap" do
      expect(liveness.headline).to include("slow — not run yet")
    end

    it "calls a stale slow tier stale" do
      tiers = { "fast" => { "ran_at" => now.iso8601 }, "slow" => { "stale" => true } }

      expect(liveness("tiers" => tiers).headline).to include("slow ⚠stale")
    end

    it "tells the reader not to trust green when down" do
      expect(described_class.new(status: nil, now:, change_set:).headline)
        .to include("Do not trust green")
    end
  end
end
