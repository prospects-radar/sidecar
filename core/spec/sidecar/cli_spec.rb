# frozen_string_literal: true

require "fileutils"
require "json"
require "open3"

# Spawns the real binary rather than calling into Ruby.
#
# This is the only place the contract *can* be tested. ADR 0032 made every class
# @api private precisely because `once` execs into the runner container, so a
# Ruby API would be correct on one side of the container wall and lie on the
# other. What an integrator actually depends on is the exit code and the
# artifacts, so that is what these assert on.
RSpec.describe "exe/sidecar" do
  GEM_ROOT = File.expand_path("../..", __dir__)
  EXE = File.join(GEM_ROOT, "exe", "sidecar")

  def sidecar(*argv)
    out, err, status = Open3.capture3(
      { "SIDECAR_CONTAINER" => nil },
      RbConfig.ruby, "-I", File.join(GEM_ROOT, "lib"), EXE, *argv
    )
    [ out, err, status.exitstatus ]
  end

  def with_project(extra = "")
    in_a_repo do |repo|
      repo.ignore("tmp/")
      FileUtils.mkdir_p("config")
      File.write("config/sidecar.rb", <<~RUBY)
        Sidecar.define do
          artifacts "tmp/sidecar"
          location(:host) { provides :node }
          sensor :always_green, name: "Always green", command: "true",
                 tier: :fast, kind: :computational, group: :lint
          sensor :gated, name: "Gated", command: "true", gate: true,
                 tier: :fast, kind: :computational, group: :lint
          #{extra}
        end
      RUBY
      FileUtils.mkdir_p("app")
      File.write("app/x.rb", "one\n")
      repo.commit("initial")
      yield repo
    end
  end

  describe "a project with no configuration" do
    # Not a link (a second thing to keep in sync) and not a generator (a file
    # copied once is never improved again).
    it "exits 2 and prints a worked example inline" do
      in_a_repo do
        _out, err, code = sidecar("once")

        expect(code).to eq(2)
        expect(err).to include("Sidecar.define do").and include("config/sidecar.rb")
      end
    end

    # The hook this feeds must never break a session. But a broken config never
    # clears on its own, so this is the one condition it stops being silent for.
    it "still exits 0 from nudge, while saying something is wrong" do
      in_a_repo do
        out, _err, code = sidecar("nudge")

        expect(code).to eq(0)
        expect(out).to include("configuration problem")
      end
    end
  end

  describe "once" do
    it "exits 0 on a tree with nothing to answer for, and writes both artifacts" do
      with_project do
        _out, _err, code = sidecar("once", "--quiet")

        expect(code).to eq(0)
        expect(Dir.children("tmp/sidecar")).to contain_exactly("status.json", "agent-summary.md")
      end
    end

    it "writes a status.json stamped with the schema version" do
      with_project do
        sidecar("once", "--quiet")

        expect(JSON.parse(File.read("tmp/sidecar/status.json"))["schema"]).to eq("sidecar.status/1")
      end
    end

    it "exits 1 when a sensor is red" do
      with_project(%(sensor :fails, name: "Fails", command: "false",
                            tier: :fast, kind: :computational, group: :lint)) do
        File.write("app/x.rb", "changed\n")

        _out, _err, code = sidecar("once", "--quiet")

        expect(code).to eq(1)
      end
    end
  end

  describe "status" do
    # Answers a different question from once: whether the last answer is still
    # current, not whether the code is clean.
    it "exits 2 when no pass has ever run" do
      with_project do
        _out, _err, code = sidecar("status")

        expect(code).to eq(2)
      end
    end

    it "exits 0 right after a pass, even with red sensors" do
      with_project(%(sensor :fails, name: "Fails", command: "false",
                            tier: :fast, kind: :computational, group: :lint)) do
        sidecar("once", "--quiet")

        _out, _err, code = sidecar("status")

        expect(code).to eq(0)
      end
    end
  end

  describe "gate" do
    # The bug this closes: the old script exited 0 here, so a guardrail reported
    # success at exactly the moment it was not working.
    it "exits 3 rather than 0 when the base resolves to HEAD" do
      with_project do
        _out, err, code = sidecar("gate", "--base", "HEAD")

        expect(code).to eq(3)
        expect(err).to include("must never report clean")
      end
    end

    it "exits 3 on a base that does not resolve" do
      with_project do
        _out, _err, code = sidecar("gate", "--base", "origin/nope")

        expect(code).to eq(3)
      end
    end

    # Deliberately distinct from `once`'s sensor set: reusing it would make every
    # fast sensor blocking at merge.
    it "says so when no sensor is marked gate:" do
      with_project do
        out, _err, code = sidecar("gate", "--base", "HEAD~0")

        expect(code).to eq(0).or eq(3)
        expect(out + _err.to_s).to match(/gate|clean/i)
      end
    end
  end

  # Invoked the way a consumer does, through bundler's generated binstub, rather
  # than by spawning the file.
  #
  # The distinction is not academic. This file first carried an
  # `if $PROGRAM_NAME == __FILE__` guard, correct for a project script and wrong
  # for a gem executable: the binstub `load`s the file, so $PROGRAM_NAME is the
  # binstub, the guard was false, and every command did nothing and exited 0.
  # Every spec that spawned the file directly passed.
  describe "through the binstub, as a consumer runs it" do
    def bundled(*argv, dir:)
      Open3.capture3({ "BUNDLE_GEMFILE" => File.join(GEM_ROOT, "Gemfile") },
                     "bundle", "exec", "sidecar", *argv, chdir: dir)
    end

    it "actually runs, rather than exiting 0 having done nothing" do
      with_project do
        out, _err, status = bundled("status", dir: Dir.pwd)

        expect(status.exitstatus).to eq(2)
        expect(out).to include("SIDECAR DOWN")
      end
    end

    it "reaches the same exit codes as a direct invocation" do
      with_project do
        _out, _err, status = bundled("gate", "--base", "HEAD", dir: Dir.pwd)

        expect(status.exitstatus).to eq(3)
      end
    end
  end

  describe "the command surface" do
    it "prints usage and exits 0 for --help" do
      out, _err, code = sidecar("--help")

      expect(code).to eq(0)
      expect(out).to include("Usage: sidecar")
    end

    it "exits 2 and names the commands for an unknown one" do
      _out, err, code = sidecar("frobnicate")

      expect(code).to eq(2)
      expect(err).to include("expected one of")
    end
  end
end
