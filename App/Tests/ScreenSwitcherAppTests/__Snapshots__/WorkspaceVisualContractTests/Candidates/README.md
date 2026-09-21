# Candidate visual snapshots

Native PNGs are deterministic local implementation candidates for human visual
review. They are not committed here, are not SnapshotTesting reference images,
and are never treated as a human-approved visual baseline.

Candidate matrix:

- App counts: 1, 10, 12, 24, and 27 Apps at the fixed 1512 x 982 viewport.
- Display counts: one display (rail hidden) and three displays (rail visible).
- Appearance: Switch dark and Switch light.
- Accessibility: Reduce Motion, Reduce Transparency, and Increase Contrast.

The 10 Apps candidate is the exact one-row/10-column boundary. The 27 Apps
candidate exercises paging and page dots. All candidates retain the same fixed
viewport and deterministic schematic preview.

Regenerate on the pinned macOS environment with:

```bash
RECORD_WORKSPACE_VISUAL_CANDIDATES=1 swift test --package-path apps/screen-switcher/macos --filter WorkspaceVisualContractTests/testDeterministicSwitchSemanticSnapshots
```

The default output is:

```text
apps/screen-switcher/macos/.build/workspace-visual-candidates/*.candidate.png
```

Set `WORKSPACE_VISUAL_CANDIDATE_DIR` to use another local artifact directory.
Only sibling semantic text snapshots run as ordinary CI assertions. The native
render assertion reports the typed skip `native_visual_baseline_unapproved`
unless `WORKSPACE_VISUAL_BASELINE_APPROVED=1` and a separately reviewed pinned
baseline exists. Candidate files alone can never satisfy that gate.

After human review, the single recording command for the pinned approved native
baseline is:

```bash
RECORD_WORKSPACE_APPROVED_NATIVE_BASELINE=1 swift test --package-path apps/screen-switcher/macos --filter WorkspaceVisualContractTests/testHumanApprovedNativeRenderBaseline
```

It records exactly
`ApprovedNative/switch-dark.approved.png`; the gate and SnapshotTesting
comparison both derive that same path from
`WorkspaceApprovedNativeBaselineContract`. Recording alone does not mark the
image approved. Subsequent comparisons require
`WORKSPACE_VISUAL_BASELINE_APPROVED=1`; that setting fails with the typed
`native_visual_baseline_approved_but_missing` error when the exact file is
absent.
