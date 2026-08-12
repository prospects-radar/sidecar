# frozen_string_literal: true

require "fileutils"
require_relative "../../lib/sidecar"

RSpec.describe "Sidecar.load" do
  # Every example writes a real config file into a real repository, because most
  # of what this layer does is refuse — and each refusal is about the project on
  # disk, not about a value in memory.
  def with_config(body, ignore: "tmp/")
    in_a_repo do |repo|
      repo.ignore(ignore) unless ignore.nil?
      FileUtils.mkdir_p("config")
      File.write("config/sidecar.rb", body)
      repo.commit("initial")
      yield repo
    end
  end

  def minimal(extra = "")
    <<~RUBY
      Sidecar.define do
        artifacts "tmp/sidecar"
        location(:host) { provides :node }
        sensor :rubocop, name: "RuboCop", command: "rubocop",
               tier: :fast, kind: :computational, group: :lint
        #{extra}
      end
    RUBY
  end

  describe "a project that says nothing" do
    it "refuses, and prints a worked example rather than inventing defaults" do
      in_a_repo do
        expect { Sidecar.load }.to raise_error(Sidecar::MissingConfig, /Sidecar\.define do/m)
      end
    end

    it "names the path it looked for" do
      in_a_repo do
        expect { Sidecar.load }.to raise_error(Sidecar::MissingConfig, %r{config/sidecar\.rb})
      end
    end

    it "refuses a file that never calls define" do
      with_config("# nothing here\n") do
        expect { Sidecar.load }.to raise_error(Sidecar::MissingConfig, /did not call Sidecar\.define/)
      end
    end
  end

  describe "a valid project" do
    it "returns a frozen value" do
      with_config(minimal) { expect(Sidecar.load).to be_frozen }
    end

    it "carries the assembled registry" do
      with_config(minimal) { expect(Sidecar.load.registry.ids).to eq(%i[rubocop]) }
    end

    it "defaults the diff base to the working tree's own HEAD" do
      with_config(minimal) { expect(Sidecar.load.base).to eq("HEAD") }
    end

    # Recorded rather than guarded: core cannot tell an expensive require from a
    # legitimate one, so a config that boots Rails shows up as the number it is.
    it "records how long the config took to load" do
      with_config(minimal) { expect(Sidecar.load.load_ms).to be_a(Integer) }
    end

    it "reports what a location provides" do
      with_config(minimal) { expect(Sidecar.load.location(:host).provides).to eq(%i[node]) }
    end

    it "falls back to a readable description for a resource nobody described" do
      with_config(minimal) { expect(Sidecar.load.location(:host).describe(:node)).to eq("node") }
    end
  end

  describe "refusals" do
    # A typo would otherwise make the sensor permanently unavailable and say
    # nothing about it.
    it "refuses a need no location provides" do
      body = minimal(%(sensor :cuke, name: "C", command: "c", tier: :slow, kind: :computational,
                              group: :test, needs: [ :databse ]))

      with_config(body) do
        expect { Sidecar.load }.to raise_error(Sidecar::Project::InvalidProject, /databse/)
      end
    end

    it "refuses a container location with nothing to start" do
      with_config(minimal("location(:container) { provides :database }")) do
        expect { Sidecar.load }.to raise_error(Sidecar::Project::InvalidProject, /needs `compose_file`/)
      end
    end

    # The same absolute path means two different directories on the two sides of
    # the container wall.
    it "refuses an absolute artifacts path" do
      with_config(minimal.sub('"tmp/sidecar"', '"/var/sidecar"')) do
        expect { Sidecar.load }.to raise_error(Sidecar::Project::InvalidProject, /both sides of the container wall/)
      end
    end

    # The watcher writes there and polls the same tree, so every pass would
    # trigger the next. It presents as a busy sidecar rather than as a
    # misconfiguration, which is why it is worth a git call at load time.
    it "refuses an artifacts path git is not ignoring" do
      with_config(minimal, ignore: nil) do
        expect { Sidecar.load }.to raise_error(Sidecar::Project::InvalidProject, /never settle/)
      end
    end

    # Better than a version constraint: it names the setting and the file, where
    # a constraint would name a number.
    it "refuses an unknown setting by name" do
      with_config(minimal('artefacts "tmp/typo"')) do
        expect { Sidecar.load }.to raise_error(Sidecar::Project::InvalidProject, /unknown setting artefacts/)
      end
    end
  end

  describe "#missing_for" do
    it "names what this location cannot give a sensor" do
      with_config(minimal) do
        project = Sidecar.load
        sensor = Sidecar::Sensor.build(:cuke, name: "C", command: "c", tier: :slow,
                                              kind: :computational, group: :test, needs: %i[node browser])

        expect(project.missing_for(sensor, at: :host)).to eq(%i[browser])
      end
    end

    it "treats an undeclared location as providing nothing, rather than raising" do
      with_config(minimal) do
        project = Sidecar.load
        sensor = Sidecar::Sensor.build(:cuke, name: "C", command: "c", tier: :slow,
                                              kind: :computational, group: :test, needs: %i[node])

        expect(project.missing_for(sensor, at: :nowhere)).to eq(%i[node])
      end
    end
  end
end
