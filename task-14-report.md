# Task 14 review report — Drag-to-trash bar + multi-select polish

| Field | Value |
|-------|--------|
| Task | 14 — Drag-to-trash bar + multi-select polish |
| Base | `cf58d305ce867fc7a5578a36e1b56a139e3a0ad0` (SSH/SFTP) |
| Head | `6282b15f2` / workspace HEAD (drag-to-trash) |
| Diff | `.superpowers/sdd/review-cf58d305c..6282b15f2.diff` |
| Mode | Read-only |
| **Verdict** | **Approved** |

---

## Summary

Task 14 delivers a bottom **TrashDropBar** with drag destination and button, tree row **draggable** multi-select payloads (`StorageNodeIDList`), and a single AppModel → RemovalService pipeline shared by drop, menu, inspector, and ⌘⌫. Denied nodes are filtered; mixed sources queue sequential confirms by source kind. All three must-checks pass.

---

## Must-check results

### 1. Same RemovalService path as menu — PASS

Design §6.6 / §7: *“Same confirmation and RemovalService pipeline as menu/⌘⌫”* and *“Single code path for drag, menu, and keyboard.”*

| Entry point | Path |
|-------------|------|
| Context menu “Move to Trash” | `requestTrashFromContext` → `requestTrashForSelection` / `requestTrash(nodeIDs:)` |
| Global / bar ⌘⌫ | `requestTrashForSelection()` |
| Inspector multi “Move to Trash” | `requestTrashForSelection()` |
| Drop bar button | `requestTrashForSelection()` |
| Drop destination | `handleTrashDrop(nodeIDs:)` → resolve nodes → `trashableNodes` → **`requestTrashResolvingSources`** |

Shared pipeline after staging:

1. `RemovalService.trashableNodes` (exclude `.denied`)
2. `AppModel.requestTrashResolvingSources` → location → `ScanSource`
3. `removalService.requestTrash` (one group) or `requestTrashGrouped` (multi)
4. `ConfirmTrashSheet` via `pendingTrash` / `isTrashConfirmPresented`
5. `confirmTrash()` → `removalService.confirmPending()` → `ScanSource.trash` → index `remove`

UI never calls `ScanSource.trash` directly. Drop does not bypass confirm.

Evidence:

- `Sources/Cistilka/UI/TrashDropBar.swift` — button + `dropDestination` → model only
- `Sources/Cistilka/App/AppModel.swift` — `handleTrashDrop` comment and call into `requestTrashResolvingSources`
- `Sources/Cistilka/UI/ContentView.swift` — same sheet + hidden ⌘⌫ button as menu path
- `Sources/Cistilka/Removal/RemovalService.swift` — sole perform path

### 2. Mixed source group — PASS

Design §7: *“Mixed multi-select: group by source.”* Plan: *“group confirm by sourceKind.”*

| Behavior | Evidence |
|----------|----------|
| Group by location → source | `AppModel.requestTrashResolvingSources` builds `byLocation`, resolves `scanSource(for:)` |
| Multi-group staging | `removalService.requestTrashGrouped(groups:)` |
| Kind order | local → googleDrive → oneDrive → ssh |
| Sequential confirm | `pendingQueue`; `confirmPending` stages next group after perform |
| Sheet copy | `remainingGroupCount` + detail *“N more source group(s)…”* |
| Skip unsupported | `supportsTrash == false` and empty trashable sets skipped; notice if none left |
| Tests | `testRequestTrashGroupedQueuesBySourceKind`, `testRequestTrashGroupedSkipsUnsupportedSource` |

Note: the tree UI is **per selected location**, so true cross-source multi-select is uncommon in the current table; the service path still implements grouping correctly for any mixed node set.

### 3. Drop bar — PASS

| Requirement | Status | Evidence |
|-------------|--------|----------|
| Bottom drop target | Yes | `ContentView` detail `VStack` ends with `TrashDropBar()` |
| Visible with selection or during drag | Yes | `showBar = selectionCount > 0 \|\| isTargeted \|\| model.isNodeDragActive` |
| Internal drag payload | Yes | `StorageNodeIDList` + UTType `com.nodaysidle.cistilka.storage-node-ids`; `TreeTableView.draggable` |
| Multi-select drag | Yes | `dragPayloadIDs(for:)` returns full selection when dragging a selected row |
| Highlight states | Yes | `isTargeted` red fill/stroke, `trash.fill`, “Drop to move to Trash” |
| Same confirm / service | Yes | See must-check 1 |
| Disable denied / unsupported | Yes | Button `.disabled(!canTrashSelection)`; drop filters via `trashableNodes`; secondary labels for denied / unsupported source; context menu disables denied rows |

---

## Plan / design coverage

| Plan / design item | Status |
|--------------------|--------|
| Create `UI/TrashDropBar.swift` | Done |
| Tree drag + drop destination | Done (`TreeTableView` + `StorageNodeDrag`) |
| Same `requestTrash` / RemovalService as menu/⌘⌫ | Done |
| Mixed sources: group confirm | Done (`requestTrashGrouped` + tests) |
| Disable drop/trash for denied / unsupported | Done (filter + disable + notices) |
| Confirm: count, size, source; SSH strong confirm | Done (`PendingTrashRequest` / `ConfirmTrashSheet`) |
| Success updates index | Done (`performTrash` → `index.remove`) |
| Manual verification checklist (plan Step 1) | Not verifiable without git commit message; no blocker for code review |

---

## Non-blocking notes (do not block Approved)

1. **Optimistic drop success** — `handleTrashDrop` returns `true` as soon as IDs are non-empty, then resolves nodes asynchronously. All-denied / missing IDs still “accept” the drop from SwiftUI’s perspective and show `pendingNotice`. Acceptable; could return false only after sync eligibility if IDs were always in-memory.

2. **`canAcceptDrop` during any drag** — While `isNodeDragActive`, the bar treats the drop as acceptable for highlight even if the selection is not trashable. Final gate remains on drop / button disable.

3. **Comment vs code on merge** — `requestTrashGrouped` comment says “merge same kind into one batch per source instance” but only **sorts** by kind; same-kind groups from different locations stay separate confirms. Fine for safety; update the comment or merge if product wants one sheet per kind.

4. **Custom UTI not in Info.plist** — `UTType(exportedAs: "com.nodaysidle.cistilka.storage-node-ids")` is sufficient for in-app Transferable drag; declaring `UTExportedTypeDeclarations` is optional polish for system-wide identity.

5. **`canTrashCurrentSelection` uses `selectedLocation` only** — Correct for single-location tree; if cross-location selection ever appears in UI, eligibility should consider each node’s location source, not only the selected sidebar location.

---

## Test inventory (Task 14–related)

- `RemovalServiceTests.testTrashableNodesFiltersDenied`
- `RemovalServiceTests.testRequestTrashSkipsDeniedNodes` / `testRequestTrashAllDeniedDoesNotPresent`
- `RemovalServiceTests.testRequestTrashGroupedQueuesBySourceKind`
- `RemovalServiceTests.testRequestTrashGroupedSkipsUnsupportedSource`
- `RemovalServiceTests` SSH strong-confirm cases (shared pipeline)
- UI drag/drop: plan relies on **manual** checklist (design § release: drag-to-trash)

---

## Verdict

**Approved**

All must-checks are satisfied: drop/menu/keyboard share the RemovalService confirm path; mixed sources queue grouped confirms; bottom drop bar with payload, visibility, and eligibility handling is in place. Non-blocking notes may be addressed in Task 15/16 polish if desired.
