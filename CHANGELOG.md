# Changelog

## v0.2.0
- Added ANSI color scheme (teal/amber palette, distinct from other tools
  in this space).
- Interface list now shows chipset (via `lspci`/`lsusb`), not just driver —
  useful for spotting injection-capable adapters at a glance.
- Added manual "Check for updates" menu option: compares local `VERSION`
  against the version in the GitHub repo's `main` branch, and offers
  `git pull` if run from a git checkout.
- Added SPDX license header.
- Improved banner pacing (explicit pause before dependency check runs,
  matching the deliberate step-by-step feel of similar tools).

## v0.1.0
- Initial release.
- Interactive menu: list interfaces, select interface, toggle monitor mode.
- Passive network scanning (managed-mode `iw scan`).
- Live channel survey via `airodump-ng`.
- Save captures to `.pcap`.
- Set/change monitor-mode channel.
- Startup dependency check with per-tool install prompts.
- `rfkill unblock all` helper.
- Startup banner with legal/ethical use notice.
