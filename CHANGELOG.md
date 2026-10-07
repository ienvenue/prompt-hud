# Changelog

All notable changes to Prompt HUD are listed here. Versions follow [Semantic Versioning](https://semver.org).

## [1.5.0] — 2026-10-07

First public release.

- Open a popup of your prompts next to the text cursor in any app with ⌃/, search, and insert with ↵. Your clipboard is restored afterwards.
- Capture selected text as a prompt with ⌃⇧/. Similar prompts are suggested for replacement.
- Save a prompt from a web page: a `prompthud://add?title=…&category=…&prompt=…` link opens the capture form already filled in. Nothing is saved until you press ⌘↵.
- Categories, pins, and in-place preview of a prompt's text. After a prompt has been used enough times (100 by default, adjustable), only its title is shown.
- Sync across Macs through iCloud Drive, with automatic merging and local backups.
- Warning when a global shortcut clashes with a system shortcut.
- English and Simplified Chinese interface.
- Ready-to-use download for Apple silicon and Intel Macs, built by GitHub Actions from this repository. It is not notarized; see the install steps in the release notes.
