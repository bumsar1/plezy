# bumsar1/plezy

Personal fork of [edde746/plezy](https://github.com/edde746/plezy) for adding
[Jimaku](https://jimaku.cc) subtitle search.

- Builds: the rolling [nightly pre-release](https://github.com/bumsar1/plezy/releases/tag/nightly)
  (Windows x64 installer/portable, macOS DMG), made by
  `.github/workflows/fork-nightly.yml` every night from upstream main merged
  with this fork.
- Upstream's own workflows (CI, Build, Update Packages) are disabled in this fork.
- Keeping the branch current: "Sync fork" on GitHub, or `git pull upstream main`.
- Fork builds have the auto-updater off, so they never replace themselves with
  the official release.
- macOS builds are ad-hoc signed; run once after installing:
  `xattr -dr com.apple.quarantine /Applications/Plezy.app`
