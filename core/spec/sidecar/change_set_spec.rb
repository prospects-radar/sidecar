# frozen_string_literal: true

require_relative "../../lib/sidecar/change_set"

RSpec.describe Sidecar::ChangeSet do
  # These run against real git repositories rather than a fake.
  #
  # Until this suite existed, the injected fake replaced precisely the code
  # nobody had ever exercised: `from_git`, the diff plumbing, and the line
  # arithmetic. The refusal behaviour below makes a fake impossible in principle
  # — a fake asked "does this base resolve?" would be asserting the thing under
  # test.

  describe ".from_git" do
    it "reports a tracked file the working tree modified" do
      in_a_repo("app/x.rb" => "one\n") do |repo|
        repo.commit("initial")
        repo.write("app/x.rb", "one\ntwo\n")

        expect(described_class.from_git.files).to eq(%w[app/x.rb])
      end
    end

    it "reports an untracked file" do
      in_a_repo("app/x.rb" => "one\n") do |repo|
        repo.commit("initial")
        repo.write("app/new.rb", "fresh\n")

        expect(described_class.from_git.files).to eq(%w[app/new.rb])
      end
    end

    it "ignores a file git is ignoring" do
      in_a_repo("app/x.rb" => "one\n") do |repo|
        repo.ignore("tmp/")
        repo.commit("initial")
        repo.write("tmp/scratch.rb", "noise\n")

        expect(described_class.from_git.files).to be_empty
      end
    end

    it "omits a deleted file, which has no lines left to answer for" do
      in_a_repo("app/x.rb" => "one\n", "app/y.rb" => "two\n") do |repo|
        repo.commit("initial")
        repo.delete("app/y.rb")

        expect(described_class.from_git.files).to be_empty
      end
    end

    # HEAD is the right default here and a legitimate answer: the question is
    # what you have edited since your last commit, so an empty range is the
    # expected steady state rather than a blind gate.
    it "is empty on a clean tree without refusing" do
      in_a_repo("app/x.rb" => "one\n") do |repo|
        repo.commit("initial")

        expect(described_class.from_git).to be_empty
      end
    end

    it "refuses a base that does not resolve" do
      in_a_repo("app/x.rb" => "one\n") do |repo|
        repo.commit("initial")

        expect { described_class.from_git(base: "origin/nope") }
          .to raise_error(described_class::BlindGate, /cannot resolve/)
      end
    end
  end

  describe ".from_range" do
    it "reports what the range touched" do
      in_a_repo("app/x.rb" => "one\n") do |repo|
        repo.commit("initial")
        base = repo.head
        repo.write("app/y.rb", "two\n").commit("second")

        expect(described_class.from_range(base:).files).to eq(%w[app/y.rb])
      end
    end

    # The bug this closes: DIFF_BASE=HEAD yielded an empty range, so the gate
    # scanned nothing and exited 0 — a guardrail reporting success at exactly the
    # moment it is not working.
    it "refuses when the base resolves to head" do
      in_a_repo("app/x.rb" => "one\n") do |repo|
        repo.commit("initial")

        expect { described_class.from_range(base: "HEAD") }
          .to raise_error(described_class::BlindGate, /the gate would inspect nothing/)
      end
    end

    it "refuses an unfetched ref rather than reporting clean" do
      in_a_repo("app/x.rb" => "one\n") do |repo|
        repo.commit("initial")

        expect { described_class.from_range(base: "origin/main") }
          .to raise_error(described_class::BlindGate, /unfetched, misspelled, or outside a shallow clone/)
      end
    end

    # How a too-shallow `git fetch --depth` actually presents in CI: the ref name
    # is fine, the commit is simply not in the clone.
    it "refuses when the clone is too shallow to reach the base" do
      in_a_repo("app/x.rb" => "one\n") do |repo|
        repo.commit("first")
        old = repo.head
        repo.write("app/y.rb", "two\n").commit("second")

        Dir.mktmpdir do |target|
          clone_path = File.join(target, "shallow")
          shallow = repo.shallow_clone_to(clone_path)

          Dir.chdir(shallow.dir) do
            expect { described_class.from_range(base: old) }
              .to raise_error(described_class::BlindGate, /cannot resolve/)
          end
        end
      end
    end
  end

  describe "#added_lines" do
    it "names only the lines the working tree added" do
      in_a_repo("app/x.rb" => "one\ntwo\nthree\n") do |repo|
        repo.commit("initial")
        repo.write("app/x.rb", "one\ntwo\nINSERTED\nthree\n")

        expect(described_class.from_git.added_lines("app/x.rb")).to eq(Set[3])
      end
    end

    it "treats every line of an untracked file as new" do
      in_a_repo("app/x.rb" => "one\n") do |repo|
        repo.commit("initial")
        repo.write("app/fresh.rb", "a\nb\nc\n")

        expect(described_class.from_git.added_lines("app/fresh.rb")).to eq(Set[1, 2, 3])
      end
    end

    it "counts a modified line as added, since its content is new" do
      in_a_repo("app/x.rb" => "one\ntwo\n") do |repo|
        repo.commit("initial")
        repo.write("app/x.rb", "one\nCHANGED\n")

        expect(described_class.from_git.added_lines("app/x.rb")).to eq(Set[2])
      end
    end

    it "names nothing for a file the change did not touch" do
      in_a_repo("app/x.rb" => "one\n", "app/y.rb" => "two\n") do |repo|
        repo.commit("initial")
        repo.write("app/x.rb", "one\nmore\n")

        expect(described_class.from_git.added_lines("app/y.rb")).to be_empty
      end
    end
  end

  describe Sidecar::ChangeSet::Git do
    describe ".parse_added_lines" do
      it "reads the new-file line numbers out of a unified=0 diff" do
        diff = <<~DIFF
          diff --git a/app/x.rb b/app/x.rb
          --- a/app/x.rb
          +++ b/app/x.rb
          @@ -2,0 +3,2 @@
          +added one
          +added two
          @@ -10 +12 @@
          -removed
          +replaced
        DIFF

        expect(described_class.parse_added_lines(diff)).to eq(Set[3, 4, 12])
      end

      it "does not count the +++ header as an added line" do
        diff = "--- a/x\n+++ b/x\n@@ -0,0 +1 @@\n+only\n"

        expect(described_class.parse_added_lines(diff)).to eq(Set[1])
      end

      it "is empty for a diff that only removes" do
        diff = "--- a/x\n+++ b/x\n@@ -1,2 +0,0 @@\n-gone\n-also gone\n"

        expect(described_class.parse_added_lines(diff)).to be_empty
      end
    end
  end

  # Pure set logic. These need files on disk (the constructor filters through
  # File.file?), which is why they build a repository rather than inventing paths.
  describe "scoping and selection" do
    def change_set_over(*paths)
      described_class.new(tracked: paths, git: instance_double(Sidecar::ChangeSet::Git))
    end

    around do |example|
      in_a_repo("config/sensors.rb" => "a\n", "config/ci.rb" => "b\n", "app/x.rb" => "c\n") do |repo|
        # Committed, so HEAD resolves and #select_new's examples can diff the
        # working tree against something.
        repo.commit("initial")
        example.run
      end
    end

    describe "#matching" do
      it("matches a nested glob at any depth") do
        expect(change_set_over("config/ci.rb", "config/sensors.rb").matching(%w[config/**/*.rb]))
          .to contain_exactly("config/ci.rb", "config/sensors.rb")
      end

      # fnmatch alone gives "**" its any-depth meaning only when a slash follows.
      it("matches a bare directory glob") do
        expect(change_set_over("config/ci.rb").matching(%w[config/**])).to eq(%w[config/ci.rb])
      end

      it("matches an exact path") do
        expect(change_set_over("config/ci.rb").matching(%w[config/ci.rb])).to eq(%w[config/ci.rb])
      end

      it("does not match a sibling directory") do
        expect(change_set_over("config/ci.rb").matching(%w[app/**/*.rb])).to be_empty
      end

      it("treats an empty glob list as matching nothing, leaving the caller to decide") do
        expect(change_set_over("config/ci.rb").matching([])).to be_empty
      end
    end

    describe "#intersects?" do
      it("is true when any file falls in scope") do
        expect(change_set_over("config/ci.rb")).to be_intersects(%w[config/**/*.rb])
      end

      it("is false when none do") do
        expect(change_set_over("config/ci.rb")).not_to be_intersects(%w[features/**])
      end
    end

    describe "file collection" do
      it "combines tracked and untracked, sorted and deduplicated" do
        set = described_class.new(tracked: %w[config/sensors.rb config/ci.rb],
                                  untracked: %w[config/ci.rb],
                                  git: instance_double(Sidecar::ChangeSet::Git))

        expect(set.files).to eq(%w[config/ci.rb config/sensors.rb])
      end

      it "drops paths that are not files on disk" do
        expect(change_set_over("config/ci.rb", "config/deleted.rb").files).to eq(%w[config/ci.rb])
      end
    end

    describe "#select_new" do
      subject(:change_set) { described_class.from_git }

      # The bug this guards: unioning added lines across files would let line 20,
      # new only in sensors.rb, whitelist line 20 in ci.rb.
      it "does not let one file's added lines vouch for another's" do
        File.write("config/sensors.rb", "#{'x\n' * 25}")
        offense = { file: "config/ci.rb", line: 20, rule: "X", message: "m" }

        expect(change_set.select_new([ offense ])).to be_empty
      end

      it "keeps an offence sitting on a line this change touched" do
        File.write("config/ci.rb", "one\ntwo\n")
        offense = { file: "config/ci.rb", line: 2, rule: "X", message: "m" }

        expect(change_set.select_new([ offense ])).to eq([ offense ])
      end

      it "drops an offence with no line at all" do
        File.write("config/ci.rb", "one\ntwo\n")

        expect(change_set.select_new([ { file: "config/ci.rb", line: nil, rule: "X", message: "m" } ])).to be_empty
      end
    end
  end
end
