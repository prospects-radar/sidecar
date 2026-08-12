# frozen_string_literal: true

require "open3"

require_relative "registry"

module Sidecar
  # One of the two places a pass can run: the developer's own machine, or the
  # sidecar's container. Which one matters because each is short of what the
  # other has — the machine has browsers and a node toolchain but no database the
  # sidecar may touch, the container has a database of its own and neither of the
  # others.
  Location = Data.define(:name, :provides, :descriptions) do
    def initialize(name:, provides: [], descriptions: {}) = super
    def provides?(resource) = provides.include?(resource)
    def describe(resource) = descriptions.fetch(resource) { default_description(resource) }

    private

    def default_description(resource) = resource.to_s.tr("_", " ")
  end

  # A consuming codebase as the sidecar sees it: which execution locations it
  # has and what each provides, where its artifacts go, and which sensors it
  # runs.
  #
  # Everything the sidecar cannot infer and must be told, gathered in one place
  # so that "what is this project" has a single answer rather than one per
  # command. A project that says nothing is not a project with defaults; it is
  # one the sidecar declines to watch, because the alternative is guessing at an
  # answer it would then report as fact.
  Project = Data.define(
    :root, :artifacts, :base, :compose_file, :runner_service,
    :workdir, :prepare_command, :locations, :registry, :load_ms
  ) do
    def initialize(root:, registry:, artifacts: "tmp/sidecar", base: "HEAD",
                   compose_file: nil, runner_service: "runner", workdir: "/rails",
                   prepare_command: nil, locations: {}, load_ms: nil)
      super
    end

    def location(name) = locations.fetch(name) { Location.new(name:) }
    def container? = locations.key?(:container)
    def artifacts_path = File.join(root, artifacts)

    # What this location cannot give a sensor. Anything listed means the sensor
    # is deferred rather than skipped: a check that did not run must never read
    # like a check that passed.
    def missing_for(sensor, at:)
      here = location(at)
      sensor.needs.reject { |resource| here.provides?(resource) }
    end

    # Every resource any location claims to have.
    def provided = locations.values.flat_map(&:provides).uniq
  end

  # Reopened rather than declared inside the Data.define block above: a constant
  # assigned in that block binds to the lexical scope (Sidecar) rather than to
  # the class being built, so it would have quietly become Sidecar::InvalidProject.
  class Project
    InvalidProject = Class.new(ArgumentError)
  end

  # Builds a Project from a `Sidecar.define` block.
  #
  # Precedence is defaults, then this file, then command-line flags. Environment
  # is deliberately not a layer: a setting that can be changed by an exported
  # variable is one the board cannot report honestly, because the value it shows
  # depends on which shell asked.
  class ProjectBuilder
    InvalidProject = Project::InvalidProject

    def initialize(root:)
      @root = root
      @settings = {}
      @locations = {}
      @registry = Registry.new
    end

    # Simple scalar settings. Unknown names raise, which is a better error than a
    # version constraint would be: it names the setting and the file, where a
    # constraint names a number.
    %i[artifacts base compose_file runner_service workdir prepare_command].each do |setting|
      define_method(setting) { |value| @settings[setting] = value }
    end

    def root(value = nil)
      return @root if value.nil?

      @root = value
    end

    def location(name, &block)
      builder = LocationBuilder.new(name)
      builder.instance_eval(&block) if block
      @locations[name] = builder.to_location
    end

    # Registry surface, forwarded so a config file reads as one flat DSL rather
    # than as two nested objects.
    def use(pack) = @registry.use(pack)
    def sensor(id, **attrs) = @registry.sensor(id, **attrs)
    def override(id, **attrs) = @registry.override(id, **attrs)
    def omit(id) = @registry.omit(id)

    def method_missing(name, *args)
      raise InvalidProject, "unknown setting #{name} in config/sidecar.rb (with #{args.inspect})"
    end

    def respond_to_missing?(*) = false

    def build(load_ms: nil)
      project = Project.new(root: @root, registry: @registry.freeze,
                            locations: @locations.freeze, load_ms:, **@settings)
      Validator.new(project).validate!
      project.freeze
    end

    class LocationBuilder
      def initialize(name)
        @name = name
        @provides = []
        @descriptions = {}
      end

      def provides(*resources) = @provides.concat(resources.flatten)

      # What to tell someone reading the board why a sensor could not run here.
      def describe(resource, text) = @descriptions[resource] = text

      def to_location = Location.new(name: @name, provides: @provides.uniq.freeze,
                                     descriptions: @descriptions.freeze)
    end

    # Six refusals, each for a failure that is otherwise silent and permanent.
    class Validator
      def initialize(project)
        @project = project
      end

      def validate!
        undeclared_resources!
        container_without_compose!
        absolute_artifacts!
        tracked_artifacts!
        self
      end

      private

      attr_reader :project

      # A typo here would otherwise make the sensor permanently unavailable and
      # say nothing. Declaring a resource nothing provides stays legal: that is a
      # fact worth seeing on the board, not an error.
      def undeclared_resources!
        unknown = project.registry.declared_needs - project.provided
        return if unknown.empty?

        raise InvalidProject,
              "sensors need #{unknown.inspect}, which no location provides. " \
              "Declare it with `location(:host) { provides #{unknown.first.inspect} }`, " \
              "or leave it undeclared on purpose and those sensors will read as unavailable."
      end

      def container_without_compose!
        return unless project.container?
        return if project.compose_file

        raise InvalidProject,
              "a :container location needs `compose_file`; without one there is nothing to start, " \
              "and a blank setting is indistinguishable from a project that meant to have no container."
      end

      # bin/sidecar runs on both sides of the container wall, where the same
      # absolute path means two different directories.
      def absolute_artifacts!
        return unless project.artifacts.start_with?("/")

        raise InvalidProject,
              "artifacts must be a path relative to the project root, got #{project.artifacts.inspect}; " \
              "an absolute path cannot resolve on both sides of the container wall."
      end

      # The watcher writes into the tree it polls, so a tracked artifact
      # directory makes every pass produce the change that triggers the next. It
      # never settles, and it presents as a busy sidecar rather than as a
      # misconfiguration.
      def tracked_artifacts!
        _out, _err, status = Open3.capture3("git", "-C", project.root, "check-ignore", "-q", project.artifacts)
        return if status.success?

        raise InvalidProject,
              "artifacts path #{project.artifacts.inspect} is not git-ignored. The watcher writes there and " \
              "polls the same tree, so every pass would trigger the next and the loop would never settle."
      end
    end
  end
end
