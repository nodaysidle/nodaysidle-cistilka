# Task 14 review brief — Drag-to-trash bar + multi-select polish

## Scope

Review implementation of plan Task 14 (`docs/superpowers/plans/2026-08-02-cistilka-implementation.md` § Task 14) and design §6.6 / §7 against HEAD after base `cf58d305c` (SSH/SFTP complete).

## Range

- **Base:** `cf58d305ce867fc7a5578a36e1b56a139e3a0ad0` — feat: SSH/SFTP scan profiles and safe remove
- **Head:** `6282b15f2` (or workspace HEAD after drag-to-trash) — feat: drag-and-drop trash bar for multi-select cleanup
- **Diff path:** `.superpowers/sdd/review-cf58d305c..6282b15f2.diff` (or matching `review-cf58d305c..*.diff`)

## Must checks

1. **Same RemovalService path as menu** — Drop bar (button + drop destination) and keyboard use the same confirm → `RemovalService` pipeline as context menu / ⌘⌫ (no parallel trash path that bypasses confirm or index update).
2. **Mixed source group** — Multi-select spanning sources groups confirms by source (kind/location); queue advances after each confirm; unsupported / denied filtered out.
3. **Drop bar** — Bottom trash drop target present; visible with non-empty selection or during drag; accepts internal `StorageNode` drag payload; highlight states; disables trash for denied/unsupported as appropriate.

## Expected artifacts (plan)

- `UI/TrashDropBar.swift`
- Modify: `TreeTableView.swift`, `RemovalService.swift`, `ContentView.swift` (and related AppModel / drag types as needed)
- Same confirmation sheet as menu/⌘⌫
- Mixed multi-select: group by sourceKind

## Mode

Read-only review. Verdict: **Approved** | **Needs fixes**.
