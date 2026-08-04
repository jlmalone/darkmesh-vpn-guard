class Darkmesh < Formula
  desc "Self-healing Tailscale + VPN coexistence guard with port-scoped fail-closed"
  homepage "https://github.com/jlmalone/darkmesh-vpn-guard"
  url "https://github.com/jlmalone/homebrew-tap/releases/download/darkmesh-v0.1.36/darkmesh-0.1.36.tar.gz"
  sha256 "80dc3193ec3419e365f533b5f8ac2788e53688c9dc98e49d3973f4e9b76ed6dc"
  license "MIT"

  depends_on :macos

  def install
    # All scripts + the PF guard live in libexec; the user-facing subset is
    # symlinked onto PATH (the `darkmesh` dispatcher is the front door).
    libexec.install Dir["scripts/*"]
    libexec.install "newsyslog"
    libexec.install "vpn-guard/vpn-guard.sh"

    user_tools = %w[
      darkmesh darkmesh-posture darkmesh-setup darkmesh-audit darkmesh-healthcheck darkmesh-breaker
      darkmesh-root-helper darkmesh-reconnect darkmesh-repair darkmesh-repair-tailscale darkmesh-restore-plain-network
      darkmesh-up darkmesh-panic darkmesh-captive darkmesh-diag darkmesh-experiment
      darkmesh-coexistence-trial darkmesh-transfer
      darkmesh-transfer-daemon
      darkmesh-migrate-agent install-root-helper.sh transfer-vpn-doctor darkmesh-expressvpn-tailscale
      relax-network-lock emergency-restore-internet vpn-guard.sh
    ]
    user_tools.each { |t| bin.install_symlink libexec/t }

    # PF data plus legacy plist templates used only by --legacy-agents.
    pkgshare.install Dir["vpn-guard/com.user.darkmesh-healthcheck.plist",
                         "vpn-guard/com.user.darkmesh-reconnect.plist",
                         "vpn-guard/com.user.darkmesh-netchange.plist",
                         "vpn-guard/com.user.vpnguard.plist",
                         "vpn-guard/unsafe.pf.conf",
                         "vpn-guard/sudoers.d-vpn-guard"]
    pkgshare.install "experiment.conf.example"
  end

  def caveats
    <<~EOS
      Install the signed Server Monitor app first. Then configure its single
      infrastructure agent and arm the PF kill-switch:
      Run as your user (it sudoes internally and prompts once); do NOT use sudo:

        darkmesh setup

      Then verify:

        darkmesh audit
        darkmesh status

      After `brew upgrade darkmesh`, re-run `darkmesh setup` so the supervisor
      restarts its long-lived children on the new code.

      A machine without Server Monitor can explicitly use:
        darkmesh setup --legacy-agents
    EOS
  end

  test do
    assert_match "darkmesh", shell_output("#{bin}/darkmesh help")
  end
end
