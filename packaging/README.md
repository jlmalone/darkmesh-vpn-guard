# Packaging darkmesh for Homebrew (`jlmalone/tap`)

`darkmesh.rb` is the formula. The pure-shell payload has no compilation step. Release
tarballs currently live on the public tap repository (`jlmalone/homebrew-tap`) so
Homebrew can fetch them without authentication.

## Cut a release (`vX.Y.Z`)

1. Bump the version in `darkmesh.rb`'s `url` (tag `darkmesh-vX.Y.Z`, asset
   `darkmesh-X.Y.Z.tar.gz`) and commit.
2. Build the payload tarball from the committed tree (payload only — not `packaging/`,
   so the formula's own sha never feeds back into the tarball):
   ```
   git archive --format=tar.gz --prefix=darkmesh-X.Y.Z/ \
     -o /tmp/darkmesh-X.Y.Z.tar.gz HEAD scripts vpn-guard newsyslog \
     experiment.conf.example README.md LICENSE
   ```
3. Compute the sha and paste it into `darkmesh.rb`:
   ```
   shasum -a 256 /tmp/darkmesh-X.Y.Z.tar.gz
   ```
   > ⚠️ `git archive` stamps every entry's mtime with the **commit timestamp**, so a
   > rebuild at a later commit yields a *different* sha even with identical contents.
   > Upload the **exact** tarball you sha'd here — do not rebuild it after step 3.
4. Cut the release **on the public tap repo** with that tarball as the asset
   (tag `darkmesh-vX.Y.Z`, matching the formula `url`):
   ```
   gh release create darkmesh-vX.Y.Z /tmp/darkmesh-X.Y.Z.tar.gz \
     --repo jlmalone/homebrew-tap --title "darkmesh X.Y.Z" --notes "…"
   ```
5. Publish to the tap:
   ```
   cp packaging/darkmesh.rb "$(brew --repository jlmalone/tap)/Formula/darkmesh.rb"
   git -C "$(brew --repository jlmalone/tap)" commit -am "darkmesh X.Y.Z" && \
   git -C "$(brew --repository jlmalone/tap)" push
   ```

## Install / upgrade on any node

```
brew install jlmalone/tap/darkmesh     # first time
brew upgrade darkmesh                  # later
darkmesh setup                         # configure/restart supervisor + arm PF (sudo)
darkmesh audit                         # verify
```

`darkmesh setup` runs as your user (it sudoes internally; do NOT prefix with sudo),
merges darkmesh's two persistent children and one scheduled guard into Server
Monitor's single Developer ID-signed infrastructure agent, retires the legacy
per-script LaunchAgents only after health validation, arms the PF kill-switch
(rules + sudoers in root-owned paths, never the user-writable brew prefix), and
clears legacy `~/.local/bin` copies that would shadow Homebrew. Re-run it after an
upgrade so the long-lived children restart on the new payload. A machine without
Server Monitor must opt into the legacy layout with `--legacy-agents`. Client
Web-UI credentials remain a separate setup step.

## Local test without publishing

```
brew tap-new local/dmtest
sed 's#url "https://github.com.*#url "file:///tmp/darkmesh-X.Y.Z.tar.gz"#' \
  packaging/darkmesh.rb > "$(brew --repository local/dmtest)/Formula/darkmesh.rb"
brew install local/dmtest/darkmesh && brew test local/dmtest/darkmesh && brew audit local/dmtest/darkmesh
brew uninstall darkmesh && brew untap local/dmtest
```
