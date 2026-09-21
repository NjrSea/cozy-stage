# KeyboardShortcuts pinned fork

This package vendors KeyboardShortcuts 2.4.0 from upstream commit
`1aef85578fdd4f9eaeeb8d53b7b4fc31bf08fe27`.

The fork exists because upstream 2.4.0 discards the `OSStatus` returned by
`RegisterEventHotKey` and then marks the shortcut registered in its in-memory
set. Consequently, `KeyboardShortcuts.isEnabled(for:)` can report `true` after
the operating system rejected the registration.

The maintained delta is intentionally narrow:

- `CarbonKeyboardShortcuts.register` returns the authoritative `OSStatus`.
- `KeyboardShortcuts.RegistrationResult` and `registrationResult(for:)` expose
  the latest result for the currently persisted shortcut.
- Failed candidates are not inserted into the library registration set or
  Carbon hot-key table.
- Registration ownership is tracked per `Name`, so a transient Recorder write
  cannot unregister a shared Carbon hot key still owned by another name.
- The Carbon registration call has an internal injectable boundary so the
  fork test can prove failure propagation without registering real input.
- `Bundle.keyboardShortcutsResources()` (Utilities.swift) resolves localization
  resources by preferring `KeyboardShortcuts_KeyboardShortcuts.bundle` inside
  the host app's `Resources` — where the packaging script relocates it — and
  falling back to `.module`, so `String.localized` works in both the SwiftPM
  build layout and the packaged-app layout (PR #112).
Recorder UI, UserDefaults persistence, global handlers, event dispatch, and
the single Carbon listener chain remain upstream-owned. Screen Switcher does
not add a parallel listener or custom recorder.

`README.upstream.md` is the unmodified upstream README. `LICENSE` preserves the
upstream MIT license and copyright notice.

When upgrading, compare this delta against upstream registration handling. The
fork can be removed once upstream exposes an equivalent authoritative result.
