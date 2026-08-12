# frozen_string_literal: true

require_relative "sidecar/version"
require_relative "sidecar/sensor"
require_relative "sidecar/registry"
require_relative "sidecar/project"
require_relative "sidecar/result"
require_relative "sidecar/handlers"
require_relative "sidecar/change_set"

# A continuous readout of a project's existing quality tools, narrowed to the
# lines that just changed.
#
# It owns no analysis. It decides what to invoke, narrows the findings to the
# change, and renders them. A check that cannot be expressed as an existing tool
# invoked with arguments means the tool is missing, not that this should acquire
# an analysis engine.
module Sidecar
  CONFIG_PATH = "config/sidecar.rb"

  # Raised when there is no config to read. Distinct from an invalid one: the
  # first is a project that has not been set up, the second is one that has been
  # set up wrongly, and they want different things said to them.
  MissingConfig = Class.new(StandardError)

  # The JSON Schema for status.json, shipped so the gem and its consumers
  # validate against one file rather than two copies that drift.
  #
  # Resolved relative to this file rather than through Gem.loaded_specs, which
  # returns nil for a gem loaded outside bundler's gem resolution — precisely the
  # `path:` case used every day in development, where the failure would be a nil
  # path reaching a file read.
  def self.status_schema_path = File.expand_path("../schema/status-v1.json", __dir__)

  # The current status.json schema version, written into every artifact.
  STATUS_SCHEMA = "sidecar.status/1"

  class << self
    # Describe a project. Called by config/sidecar.rb, which is the one file that
    # names its packs and so the natural place to require them.
    def define(root: Dir.pwd, &block)
      builder = ProjectBuilder.new(root:)
      builder.instance_eval(&block)
      @pending = builder
    end

    # Read a project's description. Public API, because config/ci.rb and anything
    # else that wants the registry is a supported consumer that is not the
    # sidecar.
    #
    # Loaded once per process and never reloaded. The config file sits in the
    # change set the watcher already samples, so an edit produces a digest line
    # telling you to restart rather than being silently half-applied.
    def load(root: Dir.pwd, path: CONFIG_PATH)
      full = File.expand_path(path, root)
      raise MissingConfig, missing_message(full) unless File.file?(full)

      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      @pending = nil
      Kernel.load(full)
      raise MissingConfig, "#{path} did not call Sidecar.define" if @pending.nil?

      # Recorded rather than guarded. Core cannot tell an expensive require from
      # a legitimate one, so a config that boots Rails shows up as the number it
      # is, on every pass. This is the only lever keeping the cheap-pass tenet
      # honest across consumers core will never see.
      elapsed = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round
      @pending.build(load_ms: elapsed).tap { @pending = nil }
    end

    private

    # Inline rather than a link to keep in sync, and not a generator: a file
    # copied once is never improved again.
    def missing_message(full)
      <<~TEXT
        No sidecar configuration at #{full}

        A project that says nothing is not a project with defaults; it is one the
        sidecar declines to watch, because the alternative is guessing at an
        answer it would then report as fact. Create the file:

            # config/sidecar.rb
            require "sidecar/rails"     # if you want the Rails sensor pack

            Sidecar.define do
              artifacts "tmp/sidecar"   # must be git-ignored

              location :host do
                provides :node, :browser
                describe :node, "install the node toolchain to run this"
              end

              use Sidecar::Rails::Pack

              sensor :rubocop,
                     name:    "Quality: RuboCop",
                     command: "bundle exec rubocop",
                     tier:    :fast,
                     kind:    :computational,
                     group:   :lint,
                     scope:   %w[app/**/*.rb lib/**/*.rb]
            end
      TEXT
    end
  end
end
