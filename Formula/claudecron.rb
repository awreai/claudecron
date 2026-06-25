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

  depends_on "jq"
  depends_on "bash"

  def install
    # Lay the program tree into libexec; keep bin/ lib/ templates/ together so
    # the entrypoint can resolve its siblings at runtime.
    libexec.install "bin", "lib", "templates"
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
