# Copyright (c) 2026 The claudecron authors
# SPDX-License-Identifier: MIT
#
# NOTE: The canonical copy of this formula lives in the tap repository
#       awreai/homebrew-tap. This in-repo copy is kept in sync for reference;
#       edits should land in the tap.

class Claudecron < Formula
  desc "Scheduler that runs Claude/Codex prompt loops on an interval"
  homepage "https://github.com/awreai/claudecron"
  url "https://github.com/awreai/claudecron/releases/download/v0.1.0/claudecron-0.1.0.tar.gz"
  sha256 "0000000000000000000000000000000000000000000000000000000000000000"
  license "MIT"
  version "0.1.0"

  depends_on "python@3"

  def install
    # The runner is a single self-contained Python file under bin/. Ship the
    # skills alongside it so `claudecron skills install` can wire the agents,
    # and the built-in loop prompts so `claudecron init` can seed them.
    libexec.install "bin"
    libexec.install "skills" if File.directory?("skills")
    libexec.install "builtins" if File.directory?("builtins")
    (libexec/"VERSION").write("#{version}\n") unless (libexec/"VERSION").exist?

    chmod 0755, libexec/"bin/claudecron"
    bin.install_symlink libexec/"bin/claudecron"
  end

  def caveats
    <<~EOS
      claudecron is installed, but no config has been scaffolded yet.

      Initialize your config (this does NOT register the scheduler):
          claudecron init --no-scheduler

      Then, when you are ready for scheduled runs:
          claudecron scheduler install

      Verify your setup any time with:
          claudecron doctor
    EOS
  end

  test do
    assert_match version.to_s, shell_output("#{bin}/claudecron version")
    system bin/"claudecron", "doctor"
  end
end
