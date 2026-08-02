# Cistilka — Design Spec

**Date:** 2026-08-02  
**Status:** Approved for implementation planning  
**Product:** Native macOS disk & cloud space analyzer (WizTree-style)

## 1. Product summary

Cistilka helps people find what is taking up space on local disks and in cloud/remote storage. It scans local volumes and folders, Google Drive, OneDrive, and SSH/SFTP paths, then shows a dense tree with folder/file counts, sizes, and percent of parent, plus file-type totals. Users can reveal items in Finder (or browser for cloud) and clean up by dragging or sending items to Trash (cloud provider trash; never silent permanent delete for local/cloud).

### Goals

- Fast, non-blocking scans of large trees
- Dense, scannable tree UI (not treemap in v1)
- Multi-source: local, Google Drive, OneDrive, SSH
- Safe cleanup: Trash / recycle bin for local and cloud
- Smooth macOS permissions (Full Disk Access coach) and OAuth sign-in
- Hybrid distribution: powerful non-sandbox Developer ID build first; App Store sandbox later as optional reduced variant

### Non-goals (v1)

- Treemap / sunburst visualization
- Duplicate finder
- iCloud Drive dedicated API (local CloudStorage paths still scannable as local)
- Dropbox and other providers
- Permanent purge / empty trash
- Windows / Linux
- Background full-disk monitoring daemon
- Perfect APFS clone / hard-link accounting

## 2. Decisions locked

| Topic | Decision |
|-------|----------|
| Scope | Full product in one pass (local + Google + OneDrive + SSH) |
| Distribution | Hybrid: non-sandbox first; App Store later optional |
| Cloud auth | Bundled OAuth client IDs (public native + PKCE); example plist committed |
| Primary UI | Dense tree table + file-type inspector (no treemap) |
| Architecture | Native Swift 6 / SwiftUI / SPM multi-source scanner core |
| App name | Cistilka |
| Local delete | Trash via `FileManager.trashItem` |
| Min macOS | 14 |
| SSH credentials | Password or key in Keychain |

## 3. Architecture

### 3.1 Principle

One unified storage model; many scan sources. UI never talks to Google/OneDrive/SSH/disk APIs directly. It reads a shared index and issues high-level commands (scan, cancel, reveal, remove).

```
┌─────────────────────────────────────────────────────────┐
│  SwiftUI (MainActor)                                    │
│  Sidebar · Tree table · Type totals · Auth sheets       │
└──────────────────────────┬──────────────────────────────┘
                           │
┌──────────────────────────▼──────────────────────────────┐
│  App services                                           │
│  ScanCoordinator · RemovalService · AuthStore           │
│  RevealService · PermissionCoach                        │
└──────────┬───────────────┬───────────────┬──────────────┘
           │               │               │
   ┌───────▼──────┐ ┌──────▼──────┐ ┌──────▼──────┐
   │ LocalSource  │ │ CloudSources│ │ SSHSource   │
   │ (FileManager │ │ Google Drive│ │ SFTP client │
   │  + FDA)      │ │ OneDrive    │ │             │
   └───────┬──────┘ └──────┬──────┘ └──────┬──────┘
           │               │               │
           └───────────────┼───────────────┘
                           ▼
              ScanIndex (SQLite + in-memory tree)
```

### 3.2 Units

| Unit | Responsibility |
|------|----------------|
| `ScanSource` protocol | Enumerate children, stream batches, trash/delete, reveal |
| `LocalDiskSource` | Recursive filesystem walk; bookmarks + Full Disk Access |
| `GoogleDriveSource` | Drive API list + metadata; OAuth via ASWebAuthenticationSession |
| `OneDriveSource` | Microsoft Graph; same OAuth pattern |
| `SSHSource` | SFTP listing/stat; credentials in Keychain |
| `ScanCoordinator` | Queue jobs, cancel, progress, merge into index off main thread |
| `ScanIndex` | Flat node table + aggregates for type totals |
| `RemovalService` | Confirm → trash per source → update index |
| `AuthStore` | Tokens + accounts in Keychain; refresh lifecycle |
| `PermissionCoach` | Guides Full Disk Access / folder access when scan incomplete |

### 3.3 Hard rules

- No UI work on scanner threads; no disk I/O on MainActor
- Cloud/local remove = Trash (provider trash / `FileManager.trashItem`)
- SSH: remote trash path if configured; otherwise permanent delete only after explicit strong confirm
- Sandbox/App Store out of v1 binary; structure code so a sandboxed target can be added later

## 4. Scanning model & data shapes

### 4.1 Location

Durable scan target (not a one-off path string).

| Field | Purpose |
|-------|---------|
| `id` | Stable UUID |
| `sourceKind` | `.local` / `.googleDrive` / `.oneDrive` / `.ssh` |
| `displayName` | Human label |
| `rootRef` | Bookmark data, drive root, Graph driveId, or `user@host:path` |
| `accountId?` | Cloud/SSH account linkage |
| `lastScannedAt?` | Staleness UI |
| `scanState` | idle / scanning / cancelled / failed / complete |

Persisted in app support; secrets only via Keychain references. Local folders may use security-scoped bookmarks.

### 4.2 StorageNode

Flat table with parent links.

| Field | Notes |
|-------|--------|
| `id` | Stable within a scan (path hash / drive fileId / remote path hash) |
| `parentId` | `nil` for roots |
| `locationId` | Owning scan |
| `name` | Display basename |
| `nodeKind` | folder / file / symlink / package / unknown |
| `logicalPath` | Display path |
| `byteSize` | See sizing rules |
| `itemCount` | Recursive file count under folders; `1` for files |
| `fileExtension` | Normalized for type totals |
| `contentType` | Optional UTI/MIME when cheap |
| `isPackage` | `.app` etc. treated as leaf by default |
| `permissionsState` | ok / denied / partial |
| `modifiedAt?` | When available |
| `remoteId?` | Cloud/SSH id for API ops |
| `scanGeneration` | Monotonic; stale rows discarded on full rescan |

**Percent of parent** is computed in the view layer:

`percentOfParent = parent.byteSize > 0 ? node.byteSize / parent.byteSize : 0`

### 4.3 Sizing rules

- **Local files:** prefer allocated size (blocks × 512) when available, else logical size
- **Packages (`.app`, etc.):** sum contents once; leaf by default (optional expand in prefs)
- **Cloud:** API size for files; folders = sum of children; finalize when enumeration completes
- **Partial scans:** running totals with scanning indicator
- **Hard links / APFS clones:** v1 best-effort separate counts (document limitation)
- **Symlinks:** do not follow by default

### 4.4 ScanJob

- `locationId`, `mode` (`full` | `refreshSubtree(nodeId)`), progress counters, error list
- **Full scan:** new generation, walk from root, stream upserts
- **Refresh subtree:** replace branch generation; re-aggregate ancestors (used after delete and “Rescan folder”)

### 4.5 Index storage

- SQLite for large trees and restart
- In-memory hot path: `nodeById`, `childrenByParentId`, incremental `typeTotals`
- Batch apply: upsert → re-sort affected siblings → ancestor sizes → type totals
- UI update cadence capped (~10–15 Hz) during scan

### 4.6 File-type totals

- Keyed by extension (`.png`, `.mov`, `(no extension)`)
- Scope: entire location or current folder
- Click type filters tree (toolbar chip)

### 4.7 Concurrency

- One active full scan per location; small parallel cap across locations (e.g. 2)
- Cooperative cancellation between batches
- Network: cancel URLSession tasks; SSH: close channel

### 4.8 Permissions & partial results

- Local EPERM/EACCES: mark denied, continue; PermissionCoach if many denials
- Cloud 401: refresh then re-auth; 403/404 mark node and continue
- SSH auth failure fails job cleanly; mid-scan disconnect keeps partial tree as incomplete

## 5. Sources & auth

### 5.1 ScanSource contract

```text
ScanSource
  enumerate(root, onBatch, onProgress) async throws
  trash(nodes) async throws -> [RemovalResult]
  reveal(node) async throws
  resolveDisplayPath(node) -> String
  supportsTrash: Bool
```

`RemovalResult`: success | movedToTrash | failed(reason)

### 5.2 Local disk

- Discover volumes via `FileManager.mountedVolumeURLs`
- Quick picks: Home, Applications, Downloads, external volumes
- Custom folder via open panel + bookmark when applicable
- Non-sandbox v1; Full Disk Access for deep scans
- PermissionCoach: explain → open System Settings → re-check; offer folder-only alternative
- Bounded worker pool (e.g. 4–8) for directory reads
- Packages as leaves by default
- Reveal: `NSWorkspace.activateFileViewerSelecting`
- Trash: `FileManager.trashItem` only

### 5.3 Google Drive

- OAuth 2.0 authorization code + PKCE via `ASWebAuthenticationSession`
- Scope: Drive access sufficient for list + trash (document clearly at sign-in); prefer least privilege that still allows trash
- Config: `Config/OAuth.example.plist` committed; `Config/OAuth.plist` gitignored with real client IDs
- Missing config: cloud disabled with setup copy; local/SSH still work
- API: Drive v3 `files.list` by parent; fields id, name, mimeType, size, parents, modifiedTime
- Native Google Docs may have size 0 in v1
- My Drive first; Shared drives if straightforward in same pass
- Trash: mark trashed (not permanent delete)
- Reveal: web URL; Finder if mirrored under `~/Library/CloudStorage/…`

### 5.4 OneDrive (Microsoft Graph)

- OAuth + PKCE via `ASWebAuthenticationSession` (or MSAL if cleaner)
- Scopes: `Files.ReadWrite`, `User.Read`, offline_access (default personal `/me/drive`)
- Same OAuth.plist pattern for Microsoft client ID + redirect URI / URL scheme
- List children with id, name, size, folder, file, parentReference, lastModifiedDateTime, webUrl
- Trash: Graph delete to recycle bin (verify at implement time; never purge endpoint)
- Reveal: webUrl or Finder if CloudStorage path exists

### 5.5 SSH / SFTP

Profile: host, port, username, auth (password or key + passphrase), remotePath, displayName, optional remote trash path.

- Secrets in Keychain; host key TOFU with change warning
- Prefer in-process SFTP (e.g. Citadel/NIOSSH or equivalent SPM library); no free-form shell from UI paths
- Scan: readdir + attrs; low parallelism (2–4)
- Remove: rename to remote trash path if set; else strong permanent-delete confirm
- Reveal: copy path + optional Open in Terminal

### 5.6 Auth UX & security

- Accounts preferences: Google / Microsoft / SSH profiles
- Silent token refresh; banner + re-auth on failure
- Sign out deletes Keychain items (and revokes when API supports)
- No token/password logging
- Prefer public native OAuth clients + PKCE (no client secret)
- Entitlements: network client; no App Sandbox in v1

## 6. UI

### 6.1 Layout

- Standard macOS window
- Toolbar: Add Location · Rescan · Stop · Search · View options
- Navigation split: Sidebar | Tree table | Inspector (collapsible)

### 6.2 Sidebar

- This Mac (volumes, Home, quick folders)
- Cloud (signed-in roots + Sign in)
- SSH (profiles + Add)
- Scans (progress / last completed)
- Context: Rescan · Reveal root · Remove from list · Account settings

### 6.3 Tree table

| Column | Content |
|--------|---------|
| Name | Disclosure + icon + name |
| Items | Recursive count |
| Size | Human-readable |
| % Parent | Bar + percent |

Default sort: size descending, per sibling group.

- Multi-select, breadcrumbs to focus subtree without rescan
- Search filters loaded tree by name
- Progress under toolbar during scan; Stop keeps partial results
- Badges: permission denied, cloud-only, error/incomplete
- Implementation may use SwiftUI `Table` or bridged `NSOutlineView` if needed for density/virtualization

### 6.4 Inspector

- File type totals for entire location or current folder
- Selection details + Reveal / Open in browser / Copy path / Move to Trash
- Type click → filter chip on toolbar

### 6.5 Empty / first-run

Scan Home · Scan volume · Connect Google · Connect OneDrive · Add SSH · FDA help link

### 6.6 Drag to remove

- Bottom trash drop target: “Drop to move to Trash”
- Same confirmation and RemovalService pipeline as menu/⌘⌫
- Confirm shows count, total size, source; stronger copy for SSH without remote trash
- Batch progress; per-item failures listed
- Success updates index and type totals

### 6.7 Preferences

Default roots, package expand, scan parallelism, accounts, clear cached scans, follow system appearance

## 7. Cleanup safety

| Source | Action | Permanent in v1? |
|--------|--------|------------------|
| Local | Finder Trash | No |
| Google Drive | API trash | No |
| OneDrive | Recycle bin | No |
| SSH + trash path | Rename into path | No |
| SSH without trash path | Explicit confirm | Only after confirm |

- Always confirm with count + size + source
- Mixed multi-select: group by source
- Extra confirm for removing entire scan roots
- Update index only for successful removals
- No custom undo; direct users to system/cloud Trash
- Single code path for drag, menu, and keyboard

## 8. Errors & diagnostics

| Class | Behavior |
|-------|----------|
| Local permission | Mark nodes, continue; FDA coach |
| OAuth expired | Banner; keep last index |
| Network blip | Retry with backoff; then pause + Resume |
| SSH host key change | Block until user accepts |
| Cancelled scan | Keep Partial results |
| Trash failure | Per-item error; batch continues |
| Missing OAuth.plist | Cloud disabled; local/SSH OK |

In-app Diagnostics pane with exportable log; no secrets in logs.

## 9. Testing

- **Unit:** aggregation, % parent, type totals, tree sort, generation discard, path normalization
- **Integration (local):** temp fixtures (sizes, packages, symlinks, denied dirs); trash + index update
- **Cloud/SSH:** URLProtocol mocks; optional manual SSH checklist
- **UI/perf smoke:** synthetic 100k-node index for expand/scroll
- **Manual release:** FDA, Google, Microsoft, SSH auth modes, drag-to-trash, cancel mid-scan

## 10. Project layout & delivery

```text
Cistilka/
  Package.swift
  Sources/Cistilka/
    App/
    UI/
    Scanner/
    Sources/          # Local, Google, OneDrive, SSH
    Index/
    Auth/
    Removal/
    Support/
  Tests/CistilkaTests/
  Config/OAuth.example.plist
  Scripts/
  version.env
  docs/superpowers/specs/
  README.md
  AGENTS.md
```

- SwiftPM macOS app, Swift 6, SwiftUI, min macOS 14
- Developer ID packaging scripts; non-sandbox entitlements
- OAuth example committed; real plist gitignored

### Build order (all in v1 scope)

1. App shell + local scan + SQLite index + tree UI + type totals + trash + Reveal  
2. Permissions coach + performance polish  
3. Google Drive auth + scan + trash  
4. OneDrive auth + scan + trash  
5. SSH profiles + scan + safe remove  
6. Drag-to-trash, multi-location, accounts prefs, packaging  

## 11. Success criteria

- Scan Home or a large volume without freezing the UI  
- Dense tree shows size, items, % parent; type totals match scope  
- Reveal in Finder works for local (and mirrored cloud when present)  
- Drag/menu trash uses Trash/recycle for local + cloud  
- Google Drive, OneDrive, and SSH are first-class locations with sign-in/profiles  
- FDA and OAuth failures are recoverable without restarting the app  

## 12. Approval history

- Scope: full product (C)  
- Distribution: hybrid (C)  
- Cloud auth: bundled OAuth (A)  
- UI: dense tree + type sidebar (A)  
- Architecture: native Swift multi-source (1)  
- Design sections §1–§5: approved 2026-08-02  
