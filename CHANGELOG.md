# Changelog

All notable changes to this project will be documented in this file.

## [Unreleased]

### Added

- Added the macOS Project Sidebar workspace model, persistent project and terminal organization,
  app-owned runtime registry, workspace window, and strict launch-directory handling.
- Added local Developer ID signing and Apple notarization commands that produce a checksummed,
  universal `Ghostty Dev` archive for private distribution and clean-machine testing.
- Added a release-contract regression test covering app identity, install isolation, updater
  isolation, signing, notarization, and secret-free automation.

### Changed

- Organized projects inside optional top-level sidebar folders and added inline renaming,
  native macOS source-list drag and drop, folder and project reordering, project moves between
  folders, and Finder folder drops for project creation.
- Added discoverable `make help` and `make run` commands for rebuilding and launching the debug
  macOS app with the required Metal toolchain under the distinct `Ghostty Dev` name, plus
  `make release`, `make release-run`, and `make release-install` for optimized local builds.
- Branded debug and local release builds as `Ghostty Dev` with the distinct
  `com.northshoreautomation.ghostty-dev` bundle identity, isolated Dock preferences, and upstream
  Sparkle updates disabled so the private build can coexist with the official Ghostty app.
- Persisted the project sidebar width across relaunches and window resizing, kept row text responsive
  while resizing, and immediately revealed new projects by refreshing and expanding their folder.
- Clarified that sidebar items are removed rather than deleted from disk, added folder and project
  creation to the sidebar context menu, and kept inline renaming active across status refreshes.
- Kept the project sidebar permanently visible, kept row titles leading-aligned and constrained
  within the native selection highlight, and removed shell-generated path subtitles from terminal
  rows.
- Limited quit confirmation to sidebar terminals with active foreground processes, allowing idle
  shells at their prompts to quit immediately.
