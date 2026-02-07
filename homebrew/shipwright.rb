# Homebrew formula for Shipwright
# Tap: sethdford/shipwright
# Install: brew install sethdford/shipwright/shipwright

class Shipwright < Formula
  desc "Orchestrate autonomous Claude Code agent teams in tmux"
  homepage "https://github.com/sethdford/shipwright"
  version "1.6.0"
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

  depends_on "tmux"
  depends_on "jq"

  def install
    # Install all scripts
    libexec.install Dir["scripts/*"]

    # Make scripts executable
    (libexec/"scripts").children.each { |f| f.chmod 0755 if f.file? }

    # Create bin entries — all three names point to the same router
    bin.install_symlink libexec/"cct" => "shipwright"
    bin.install_symlink libexec/"cct" => "sw"
    bin.install_symlink libexec/"cct" => "cct"

    # Install team templates
    (share/"shipwright/templates").install Dir["tmux/templates/*.json"]

    # Install pipeline templates
    (share/"shipwright/pipelines").install Dir["templates/pipelines/*.json"]

    # Install Claude Code settings template
    (share/"shipwright/claude-code").install Dir["claude-code/*"]

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
    # Create user template directories
    shipwright_dir = Pathname.new(Dir.home)/".shipwright"
    templates_dir = shipwright_dir/"templates"
    pipelines_dir = shipwright_dir/"pipelines"

    templates_dir.mkpath
    pipelines_dir.mkpath

    # Copy templates to user directory (don't overwrite existing)
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
