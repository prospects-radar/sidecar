# frozen_string_literal: true

require "json"
require "json_schemer"
require "tmpdir"

require_relative "../../lib/sidecar"
require_relative "../../lib/sidecar/report"

RSpec.describe Sidecar::Report do
  let(:change_set) { instance_double(Sidecar::ChangeSet, base: "HEAD", files: %w[app/x.rb]) }

  def result(**overrides)
    Sidecar::SensorResult.new(
      **{ id: :rubocop, name: "RuboCop", group: :lint, tier: :fast, state: :green,
          duration_ms: 12, targets: Sidecar::Targets.new(considered: 1) }.merge(overrides)
    )
  end

  around { |example| Dir.mktmpdir { |dir| @dir = dir and example.run } }

  def write(results, **rest)
    described_class.new(results:, change_set:, dir: @dir, **rest).write
    JSON.parse(File.read(File.join(@dir, "status.json")))
  end

  # ADR 0032 made the artifact the contract, so the schema is the test. It ships
  # in the gemspec so the gem and its consumers validate against one file rather
  # than two copies that drift.
  describe "the published contract" do
    let(:schema) { JSONSchemer.schema(JSON.parse(File.read(Sidecar.status_schema_path))) }

    it "writes a status.json that validates against the shipped schema" do
      errors = schema.validate(write([ result ])).to_a

      expect(errors.map { |e| e["error"] }).to be_empty
    end

    it "validates with every state a sensor can be in" do
      results = %i[green red deferred unavailable error].map { |state| result(id: state, state:) }

      expect(schema.validate(write(results)).to_a).to be_empty
    end

    it "validates with violations present" do
      violation = Sidecar::Violation.new(file: "app/x.rb", line: 3, rule: "Style/Foo", message: "no")
      status = write([ result(state: :red, new_violations: [ violation ], preexisting: [ violation ]) ])

      expect(schema.validate(status).to_a).to be_empty
    end

    it "stamps the schema version, so a reader never has to guess from an exit code" do
      expect(write([ result ])["schema"]).to eq("sidecar.status/1")
    end
  end

  describe "totals" do
    it "counts unavailable separately from deferred, because the fix differs" do
      results = [ result(id: :a, state: :deferred), result(id: :b, state: :unavailable) ]

      expect(write(results)["totals"]).to include("deferred" => 1, "unavailable" => 1)
    end

    it "counts an unreadable tool as red, since it is something to answer for" do
      expect(write([ result(state: :error) ])["totals"]["red"]).to eq(1)
    end
  end

  describe "tiers" do
    # So a reader can tell "not run yet" from "run and current".
    it "omits the slow tier until it has produced something" do
      expect(write([ result ])["tiers"]).not_to have_key("slow")
    end

    it "reports the slow tier as stale when its verdict is about a tree that moved" do
      slow = result(id: :full, tier: :slow, stale: true)

      expect(write([ slow ])["tiers"]["slow"]).to include("stale" => true)
    end
  end

  describe "the core stanza" do
    it "records which location wrote the file, so version skew is visible" do
      status = write([ result ], location: :container)

      expect(status["core"]).to include("version" => Sidecar::VERSION, "location" => "container")
    end
  end

  # A reader arriving mid-write must get the previous pass in full rather than
  # half of this one — the watch loop rewrites these every few seconds while an
  # agent may be reading them.
  describe "atomicity" do
    it "leaves no temp file behind" do
      write([ result ])

      expect(Dir.children(@dir)).to contain_exactly("status.json", "agent-summary.md")
    end
  end
end
