# frozen_string_literal: true

require "open3"
require "rbconfig"

# The two rules that make "no Rails, no dependencies" checkable rather than
# aspirational.
#
# Both are checked rather than reviewed, because they rot silently and their
# first violation looks like a passing suite: a stray `require "active_support"`
# in one file would be invisible in every other spec here, and would only surface
# as a slow pass on a consumer's machine months later.
RSpec.describe "core stands alone" do
  GEM_ROOT = File.expand_path("../..", __dir__) unless defined?(GEM_ROOT)
  LIB = File.join(GEM_ROOT, "lib")

  files = Dir[File.join(LIB, "sidecar", "*.rb")].sort

  it "has files to check, so a broken glob cannot pass this vacuously" do
    expect(files.size).to be >= 10
  end

  # In-process assertion would be worthless: RSpec's own boot could define Rails,
  # and by the time this file runs the whole tree is already loaded. A fresh
  # subprocess per file is the only way to learn what that file drags in.
  describe "loading with Rails undefined" do
    files.each do |path|
      name = "sidecar/#{File.basename(path, '.rb')}"

      it "loads #{name} without pulling in Rails" do
        script = %(require #{name.inspect}; exit(defined?(Rails) ? 1 : 0))
        _out, err, status = Open3.capture3(RbConfig.ruby, "-I", LIB, "-e", script)

        expect(status.exitstatus).to eq(0), "#{name} defined Rails, or failed: #{err}"
      end
    end

    it "loads the whole gem without pulling in Rails" do
      script = %(require "sidecar"; exit(defined?(Rails) ? 1 : 0))
      _out, err, status = Open3.capture3(RbConfig.ruby, "-I", LIB, "-e", script)

      expect(status.exitstatus).to eq(0), err
    end
  end

  # What makes the "boots nothing" tenet a fact rather than a promise. Every
  # library core uses — open3, set, json, fileutils, shellwords, time, etc — is
  # stdlib, so this list staying empty is the whole claim.
  describe "the gemspec" do
    let(:spec) { Gem::Specification.load(File.join(GEM_ROOT, "sidecar-core.gemspec")) }

    it "declares no runtime dependencies at all" do
      expect(spec.runtime_dependencies.map(&:name)).to be_empty
    end

    # Resolved __dir__-relative at runtime, so they have to actually ship.
    # Gem.loaded_specs would return nil under a path: source, which is the case
    # used every day in development.
    it "ships the files the code resolves relative to itself" do
      expect(spec.files).to include("schema/status-v1.json", "compose/base.yml")
    end

    it "ships the executable" do
      expect(spec.executables).to eq([ "sidecar" ])
    end

    # A shipped test helper would be a third public surface to version for a gem
    # with one consumer.
    it "does not ship its own spec suite" do
      expect(spec.files.grep(%r{\Aspec/})).to be_empty
    end
  end

  # Cancellation lives in the runner. A handler reaching for Open3 directly gets
  # a sensor that cannot be stopped mid-run, so a pass keeps burning CPU on a
  # tree that already moved — which breaks the founding tenet and presents as a
  # sluggish machine nowhere near its cause.
  #
  # No static check can catch this in a project's own handler, since those live
  # in repos this gem never sees. What is checkable is that the ones core ships
  # set the example.
  describe "the shipped handlers" do
    # Read as a syntax tree, not as text. A grep over the source fails here for a
    # silly reason: the comment explaining *why* handlers must not touch Open3
    # contains the word Open3.
    it "execute nothing except through the runner they are given" do
      require "prism"
      root = Prism.parse_file(File.join(LIB, "sidecar", "handlers.rb")).value

      expect(execution_calls_in(root)).to be_empty
    end

    def execution_calls_in(node, found = [])
      if node.is_a?(Prism::CallNode)
        found << node.name if %i[system spawn exec ` popen3 capture3 capture2].include?(node.name)
        found << "Open3" if node.receiver.is_a?(Prism::ConstantReadNode) && node.receiver.name == :Open3
      end
      node.compact_child_nodes.each { |child| execution_calls_in(child, found) }
      found
    end
  end
end
