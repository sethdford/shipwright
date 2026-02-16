# Homebrew formula for Shipwright
# Tap: sethdford/shipwright
# Install: brew install sethdford/shipwright/shipwright

class Shipwright < Formula
  desc "Orchestrate autonomous Claude Code agent teams in tmux"
  homepage "https://github.com/sethdford/shipwright"
  version "2.2.0"
  license "MIT"

  on_macos do
    if Hardware::CPU.arm?
      url "https://github.com/sethdford/shipwright/releases/download/v#{version}/shipwright-darwin-arm64.tar.gz"
      sha256 "PLACEHOLDER_DARWIN_ARM64_SHA256"
    else
      url "https://github.com/sethdford/shipwright/releases/download/v#{version}/shipwright-darwin-x86_64.tar.gz"
      sha256 "PLACEHOLDER_DARWIN_X86_64_SHA256"
    end
  end

  on_linux do
    url "https://github.com/sethdford/shipwright/releases/download/v#{version}/shipwright-linux-x86_64.tar.gz"
    sha256 "PLACEHOLDER_LINUX_X86_64_SHA256"
  end

  depends_on "bash"
  depends_on "jq"
  depends_on "tmux"

  def install
    # Preserve tarball layout under libexec so REPO_DIR=libexec (scripts expect SCRIPT_DIR/.. = repo root)
    libexec.install "scripts" if Dir.exist?("scripts")
    libexec.install "templates" if Dir.exist?("templates")
    libexec.install "tmux" if Dir.exist?("tmux")
    libexec.install "config" if Dir.exist?("config")
    (libexec/".claude").install Dir[".claude/agents"] if Dir.exist?(".claude/agents")
    (libexec/".claude").install Dir[".claude/hooks"] if Dir.exist?(".claude/hooks")

    # Make shell scripts executable
    Dir[libexec/"scripts/*.sh"].each { |f| File.chmod(0755, f) }
    Dir[libexec/"scripts/lib/*.sh"].each { |f| File.chmod(0755, f) } if Dir.exist?(libexec/"scripts/lib")

    # Wrapper runs libexec/scripts/sw so SCRIPT_DIR=libexec/scripts, REPO_DIR=libexec
    (bin/"shipwright").write <<~EOS
      #!/usr/bin/env bash
      exec "#{libexec}/scripts/sw" "$@"
    EOS

    (bin/"sw").write <<~EOS
      #!/usr/bin/env bash
      exec "#{libexec}/scripts/sw" "$@"
    EOS

    (bin/"cct").write <<~EOS
      #!/usr/bin/env bash
      exec "#{libexec}/scripts/sw" "$@"
    EOS

    # Install team templates to share for post_install
    (share/"shipwright/templates").install Dir["tmux/templates/*.json"] if Dir.exist?("tmux/templates")
    (share/"shipwright/pipelines").install Dir["templates/pipelines/*.json"] if Dir.exist?("templates/pipelines")

    # Install documentation
    doc.install Dir["docs/*"] if Dir.exist?("docs")

    # Install shell completions
    if Dir.exist?("completions")
      bash_completion.install "completions/shipwright.bash" => "shipwright"
      zsh_completion.install "completions/_shipwright"
      fish_completion.install "completions/shipwright.fish"
    end
  end

  def post_install
    shipwright_dir = Pathname.new(Dir.home)/".shipwright"
    templates_dir = shipwright_dir/"templates"
    pipelines_dir = shipwright_dir/"pipelines"

    templates_dir.mkpath
    pipelines_dir.mkpath

    (share/"shipwright/templates").children.each do |tpl|
      dest = templates_dir/tpl.basename
      FileUtils.cp(tpl, dest) unless dest.exist?
    end

    (share/"shipwright/pipelines").children.each do |tpl|
      dest = pipelines_dir/tpl.basename
      FileUtils.cp(tpl, dest) unless dest.exist?
    end
  end

  def caveats
    <<~EOS
      Shipwright is installed. Three commands are available:

        shipwright <command>    Full name
        sw <command>            Short alias
        cct <command>           Legacy alias

      Quick start:

        tmux new -s dev
        shipwright init
        shipwright session my-feature --template feature-dev

      Shell completions have been installed for bash, zsh, and fish.

      Full docs: https://sethdford.github.io/shipwright
    EOS
  end

  test do
    assert_match "shipwright", shell_output("#{bin}/shipwright version")
    assert_match "shipwright", shell_output("#{bin}/sw version")
  end
end
