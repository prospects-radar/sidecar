# frozen_string_literal: true

require "prism"
require "sidecar/rails"

RSpec.describe Sidecar::Rails do
  LIB_FILES = Dir[File.expand_path("../../lib/**/*.rb", __dir__)].sort

  # The rule that keeps this gem a pack rather than a second implementation.
  #
  # Checked rather than reviewed, because it rots silently and its first
  # violation looks like a passing suite. A subprocess load cannot catch it: a
  # method that is never called never runs, so only reading the syntax tree
  # proves the method is not there at all.
  describe "declarations only" do
    it "has files to check, so a broken glob cannot pass this vacuously" do
      expect(LIB_FILES.size).to be >= 4
    end

    LIB_FILES.each do |path|
      relative = path.split("/lib/").last

      it "defines no methods in lib/#{relative}" do
        defs = nodes_of_type(Prism.parse_file(path).value, Prism::DefNode)

        expect(defs.map { |node| node.name }).to be_empty
      end

      it "shells out nowhere in lib/#{relative}" do
        calls = nodes_of_type(Prism.parse_file(path).value, Prism::CallNode)
        executors = calls.map(&:name) & %i[system exec spawn ` popen popen3 capture3 capture2]

        expect(executors).to be_empty
      end
    end
  end

  describe "the packs" do
    it "ships the base pack a Rails codebase always wants" do
      expect(ids_in(described_class::Pack)).to eq(%i[db_setup rubocop brakeman assets_precompile])
    end

    # RSpec is not Rails' default test framework, so it is not in the base pack.
    it "keeps RSpec separate" do
      expect(ids_in(described_class::RSpecPack)).to eq(%i[rspec_smoke targeted_specs rspec_full])
    end

    # A Rails 8 app on esbuild has no importmap.
    it "keeps importmap separate" do
      expect(ids_in(described_class::ImportmapPack)).to eq(%i[importmap_audit])
    end

    it "declares every sensor validly" do
      registry = Sidecar::Registry.new

      expect { [ described_class::Pack, described_class::RSpecPack, described_class::ImportmapPack ]
                 .each { |pack| registry.use(pack) } }.not_to raise_error
    end

    # A pack cannot see the machine. One asserting node would hand half its
    # consumers a failing sensor where the honest answer is unavailable.
    it "declares no provides, leaving that to the project" do
      defaults = Sidecar::Registry.defaults_in(described_class::Pack)

      expect(defaults).not_to have_key(:provides)
    end

    # Vanilla, so a project on parallel_tests has to say so. That keeps the pack
    # honest about what it assumes instead of shipping someone else's setup.
    it "ships db_setup in its vanilla form" do
      db_setup = described_class::Pack[:sensors].find { |s| s[:id] == :db_setup }

      expect(db_setup[:command]).to eq("bin/rails db:test:prepare")
    end
  end

  # A Railtie runs during Rails boot, and nothing in the sidecar's path goes
  # through Rails boot. #520's decision table said otherwise; #529 superseded it.
  it "defines no Railtie" do
    expect(defined?(Sidecar::Rails::Railtie)).to be_nil
  end

  it "declares no dependency on rails itself" do
    spec = Gem::Specification.load(File.expand_path("../../sidecar-rails.gemspec", __dir__))

    expect(spec.runtime_dependencies.map(&:name)).to eq(%w[sidecar-core])
  end

  def ids_in(pack) = pack[:sensors].map { |sensor| sensor[:id] }

  def nodes_of_type(node, type, found = [])
    found << node if node.is_a?(type)
    node.compact_child_nodes.each { |child| nodes_of_type(child, type, found) }
    found
  end
end
