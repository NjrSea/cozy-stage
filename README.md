<div align="center">

<img src="assets/icon.png" width="128" alt="The Cozy Stage app icon">

# Cozy Stage

**Native macOS switcher — see every Screen, activate the exact window.**

[Download the beta](https://sundaydesk.app/products/cozy-stage/) · [Build from source](docs/build.md) · [Report an issue](../../issues)

</div>

![Cozy Stage HUD — the Workspace Overview across displays](assets/hero.png)

Cozy Stage is a native macOS menu bar app for people who work across many
windows and displays. One keystroke opens the Workspace Overview HUD: every
Screen on every display in one ordered view, keyboard-first selection, and
activation of the exact window you mean — without rearranging your windows.

## Highlights

- Workspace Overview HUD across every connected display
- Activate the exact window, not just the app
- Quick Close closes a Screen without quitting the shared app process
- Global keyboard shortcuts with flexible bindings
- Native AppKit/SwiftUI — no Electron, no helper daemons

## Build from source

Requirements: macOS 14+, Swift 6.1+ toolchain (Xcode 16.3+).

    swift build
    swift run ScreenSwitcherApp

The app asks for Accessibility permission on first launch — window switching
needs it. Testing and a manual .app bundle recipe live in docs/build.md.

## Download the ready-made beta

Prefer not to build? Get the current Cozy Stage beta and launch news by email:
https://sundaydesk.app/products/cozy-stage/

## Status

Cozy Stage is free while in active development and is planned as a single
one-time purchase at launch. This repository is mirrored from internal development and synced at each release — issues are welcome, but there is
no SLA; see CONTRIBUTING.md.

## License

MIT — see [LICENSE](LICENSE). The Cozy Stage name and logo are not covered by the license; forks must rename.

---

## More from Sunday Desk

- **[Kelyra](https://kelyra.ai/)** — turns source-grounded AI answers into durable local Markdown knowledge.
- New releases land in the Sunday Desk mailing list first — [sundaydesk.app](https://sundaydesk.app/).

Cozy Stage is made by Sunday Desk — thoughtful software for everyday work.
