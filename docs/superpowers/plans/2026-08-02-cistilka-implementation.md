# Cistilka Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build Cistilka, a native macOS WizTree-style analyzer that scans local disks, Google Drive, OneDrive, and SSH paths, shows a dense tree with sizes/counts/% parent and file-type totals, and moves items to Trash safely.

**Architecture:** Unified `StorageNode` index (SQLite + in-memory tree) fed by pluggable `ScanSource` implementations. `ScanCoordinator` runs scans off the main actor; SwiftUI binds to index snapshots. `RemovalService` routes trash per source. OAuth via ASWebAuthenticationSession + Keychain; SSH via in-process SFTP.

**Tech Stack:** Swift 6, SwiftUI, SwiftPM executable macOS app (min macOS 14), SQLite (GRDB or raw SQLite3), AuthenticationServices, URLSession, Keychain Services, optional Citadel/NIOSSH for SFTP, packaging scripts from macos-spm-app-packaging.

**Spec:** `docs/superpowers/specs/2026-08-02-cistilka-design.md`

## Global Constraints

- App name: **Cistilka**; bundle id: `com.nodaysidle.cistilka` (adjust only if user specifies otherwise)
- Swift tools version **6.2+**, platform **macOS 14+**, Swift **6** language mode / strict concurrency
- **Non-sandbox** Developer ID first; no App Sandbox entitlement in v1
- Local and cloud remove = **Trash only** (never permanent delete for local/Google/OneDrive)
- SSH permanent delete only after **strong confirm** when no remote trash path
- OAuth: public native clients + **PKCE**; real secrets in gitignored `Config/OAuth.plist`
- No treemap, no duplicate finder, no background daemon in v1
- No disk I/O on MainActor; UI updates batched ≤ ~15 Hz during scan
- TDD: write failing tests first for domain/index/scanner logic; commit after each task
- Project root for all paths below: repo workspace `cistilka-safet/` (Package.swift at this root)

---

## File structure (create as tasks proceed)

```text
Package.swift
version.env
.gitignore
README.md
AGENTS.md
Config/OAuth.example.plist
Config/OAuth.plist                 # gitignored
Sources/Cistilka/
  App/CistilkaApp.swift
  App/AppModel.swift
  Models/Location.swift
  Models/StorageNode.swift
  Models/ScanJob.swift
  Models/SourceKind.swift
  Models/RemovalTypes.swift
  Index/ScanIndex.swift
  Index/ScanIndex+TypeTotals.swift
  Index/SQLiteStore.swift
  Scanner/ScanSource.swift
  Scanner/ScanCoordinator.swift
  Scanner/LocalDiskSource.swift
  Scanner/GoogleDriveSource.swift
  Scanner/OneDriveSource.swift
  Scanner/SSHSource.swift
  Auth/OAuthConfig.swift
  Auth/AuthStore.swift
  Auth/PKCE.swift
  Auth/GoogleOAuthClient.swift
  Auth/MicrosoftOAuthClient.swift
  Auth/KeychainStore.swift
  Removal/RemovalService.swift
  Support/RevealService.swift
  Support/PermissionCoach.swift
  Support/ByteFormat.swift
  Support/DiagnosticsLog.swift
  Support/LocationStore.swift
  UI/ContentView.swift
  UI/SidebarView.swift
  UI/TreeTableView.swift
  UI/InspectorView.swift
  UI/TrashDropBar.swift
  UI/EmptyStateView.swift
  UI/ConfirmTrashSheet.swift
  UI/AccountsSettingsView.swift
  UI/SSHProfileSheet.swift
  UI/ProgressHeaderView.swift
  Resources/Info.plist
  Resources/Assets.xcassets (optional)
Scripts/package_app.sh
Scripts/compile_and_run.sh
Tests/CistilkaTests/
  ScanIndexTests.swift
  LocalDiskSourceTests.swift
  ByteFormatTests.swift
  RemovalServiceTests.swift
  TypeTotalsTests.swift
  PKCETests.swift
  PathNormalizationTests.swift
```

---

### Task 1: SwiftPM app skeleton + packaging hooks

**Files:**
- Create: `Package.swift`
- Create: `version.env`
- Create: `.gitignore`
- Create: `Sources/Cistilka/App/CistilkaApp.swift`
- Create: `Sources/Cistilka/UI/ContentView.swift`
- Create: `Sources/Cistilka/Resources/Info.plist`
- Create: `Tests/CistilkaTests/SmokeTests.swift`
- Create: `README.md`
- Create: `AGENTS.md`
- Create: `Scripts/package_app.sh` (copy/adapt from macos-spm-app-packaging template)
- Create: `Scripts/compile_and_run.sh`

**Interfaces:**
- Consumes: nothing
- Produces: runnable `Cistilka` executable target + `CistilkaTests` test target

- [ ] **Step 1: Write failing smoke test**

```swift
// Tests/CistilkaTests/SmokeTests.swift
import XCTest
@testable import Cistilka

final class SmokeTests: XCTestCase {
    func testBundleNameConstant() {
        XCTAssertEqual(AppIdentity.name, "Cistilka")
    }
}
```

- [ ] **Step 2: Create Package.swift and app sources**

```swift
// Package.swift
// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Cistilka",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Cistilka",
            path: "Sources/Cistilka",
            resources: [.process("Resources")],
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
        .testTarget(
            name: "CistilkaTests",
            dependencies: ["Cistilka"],
            path: "Tests/CistilkaTests"
        ),
    ]
)
```

Note: If `@testable import` fails because executable targets are not testable, split a `CistilkaCore` library target (models/index/scanner) and thin `Cistilka` executable that depends on it. Prefer this layout if needed:

```swift
.library(name: "CistilkaCore", targets: ["CistilkaCore"]),
.executableTarget(name: "Cistilka", dependencies: ["CistilkaCore"], ...),
.testTarget(name: "CistilkaTests", dependencies: ["CistilkaCore"], ...),
```

Implement `AppIdentity.name = "Cistilka"` in `Sources/Cistilka/Support/AppIdentity.swift` (or Core).

```swift
// Sources/Cistilka/App/CistilkaApp.swift
import SwiftUI

@main
struct CistilkaApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup("Cistilka") {
            ContentView()
                .environment(model)
        }
        Settings {
            AccountsSettingsView()
                .environment(model)
        }
    }
}
```

Stub `AppModel`, `ContentView`, `AccountsSettingsView` with minimal “Cistilka” text so the app compiles.

- [ ] **Step 3: Run tests**

```bash
cd /path/to/cistilka-safet && swift test
```

Expected: PASS for `testBundleNameConstant`.

- [ ] **Step 4: `.gitignore` and version**

```gitignore
.DS_Store
.build/
*.xcodeproj
Config/OAuth.plist
DerivedData/
*.app
```

```bash
# version.env
APP_NAME=Cistilka
BUNDLE_ID=com.nodaysidle.cistilka
VERSION=0.1.0
BUILD_NUMBER=1
```

- [ ] **Step 5: Commit**

```bash
git add Package.swift version.env .gitignore Sources Tests README.md AGENTS.md Scripts
git commit -m "chore: scaffold Cistilka SwiftPM macOS app"
```

---

### Task 2: Domain models + byte formatting

**Files:**
- Create: `Sources/Cistilka/Models/SourceKind.swift`
- Create: `Sources/Cistilka/Models/Location.swift`
- Create: `Sources/Cistilka/Models/StorageNode.swift`
- Create: `Sources/Cistilka/Models/ScanJob.swift`
- Create: `Sources/Cistilka/Models/RemovalTypes.swift`
- Create: `Sources/Cistilka/Support/ByteFormat.swift`
- Create: `Tests/CistilkaTests/ByteFormatTests.swift`
- Create: `Tests/CistilkaTests/StorageNodeTests.swift`

**Interfaces:**
- Consumes: none
- Produces:
  - `enum SourceKind: String, Codable, Sendable { case local, googleDrive, oneDrive, ssh }`
  - `struct ScanLocation: Identifiable, Codable, Sendable` with `id: UUID`, `sourceKind`, `displayName`, `rootRef: String`, `accountId: String?`, `lastScannedAt: Date?`, `scanState: ScanState`
  - `enum ScanState: String, Codable, Sendable { case idle, scanning, cancelled, failed, complete }`
  - `struct StorageNode: Identifiable, Sendable, Equatable` with fields from spec §4.2
  - `struct ScanProgress: Sendable` — `dirsVisited`, `filesVisited`, `bytesSeen`, `currentPath`
  - `enum RemovalResult: Sendable` — `movedToTrash(nodeId:)`, `failed(nodeId:message:)`
  - `ByteFormat.string(bytes: Int64) -> String`

- [ ] **Step 1: Failing tests**

```swift
func testFormatsGigabytes() {
    XCTAssertEqual(ByteFormat.string(bytes: 12_884_901_888), "12 GB") // or "12.0 GB" — pick one rule and lock it
}

func testPercentOfParent() {
    let parent = StorageNode.fixture(id: "p", byteSize: 1000, itemCount: 2)
    let child = StorageNode.fixture(id: "c", parentId: "p", byteSize: 250, itemCount: 1)
    XCTAssertEqual(child.percentOfParent(parentSize: parent.byteSize), 0.25, accuracy: 0.0001)
}

func testPercentOfParentZeroSafe() {
    let child = StorageNode.fixture(id: "c", byteSize: 10, itemCount: 1)
    XCTAssertEqual(child.percentOfParent(parentSize: 0), 0)
}
```

- [ ] **Step 2: Run tests — expect FAIL**

```bash
swift test --filter ByteFormatTests
```

- [ ] **Step 3: Implement models + ByteFormat**

```swift
enum ByteFormat {
    static func string(bytes: Int64) -> String {
        let f = ByteCountFormatter()
        f.allowedUnits = [.useAll]
        f.countStyle = .file
        f.includesUnit = true
        f.isAdaptive = true
        return f.string(fromByteCount: bytes)
    }
}

extension StorageNode {
    func percentOfParent(parentSize: Int64) -> Double {
        guard parentSize > 0 else { return 0 }
        return Double(byteSize) / Double(parentSize)
    }
}
```

Define `StorageNode` with: `id`, `parentId`, `locationId`, `name`, `nodeKind`, `logicalPath`, `byteSize`, `itemCount`, `fileExtension`, `isPackage`, `permissionsState`, `modifiedAt`, `remoteId`, `scanGeneration`.

- [ ] **Step 4: Run tests — expect PASS**

```bash
swift test --filter ByteFormatTests
swift test --filter StorageNodeTests
```

- [ ] **Step 5: Commit**

```bash
git commit -am "feat: add domain models and byte formatting"
```

---

### Task 3: ScanIndex (in-memory tree + type totals + aggregation)

**Files:**
- Create: `Sources/Cistilka/Index/ScanIndex.swift`
- Create: `Sources/Cistilka/Index/ScanIndex+TypeTotals.swift`
- Create: `Tests/CistilkaTests/ScanIndexTests.swift`
- Create: `Tests/CistilkaTests/TypeTotalsTests.swift`

**Interfaces:**
- Consumes: `StorageNode`, `ScanLocation`
- Produces:
  - `actor ScanIndex` with:
    - `func apply(batch: [StorageNode], generation: UInt64) async`
    - `func finalizeDirectory(id: String, byteSize: Int64, itemCount: Int64) async`
    - `func children(of parentId: String?) async -> [StorageNode]` sorted by current sort
    - `func node(id: String) async -> StorageNode?`
    - `func reaggregateAncestors(from nodeId: String) async`
    - `func remove(ids: Set<String>) async`
    - `func typeTotals(scopeRootId: String?) async -> [TypeTotal]`
    - `func discardGeneration(locationId: UUID, keeping generation: UInt64) async`
  - `struct TypeTotal: Sendable, Equatable { var fileExtension: String; var count: Int; var bytes: Int64 }`
  - Sort: default size descending within siblings

- [ ] **Step 1: Failing tests**

```swift
func testAggregatesFolderSizeFromChildren() async {
    let index = ScanIndex()
    let loc = UUID()
    let gen: UInt64 = 1
    await index.apply(batch: [
        .fixture(id: "root", locationId: loc, name: "root", kind: .folder, byteSize: 0, itemCount: 0, generation: gen),
        .fixture(id: "a", parentId: "root", locationId: loc, name: "a.txt", kind: .file, byteSize: 100, itemCount: 1, ext: "txt", generation: gen),
        .fixture(id: "b", parentId: "root", locationId: loc, name: "b.txt", kind: .file, byteSize: 50, itemCount: 1, ext: "txt", generation: gen),
    ], generation: gen)
    await index.finalizeDirectory(id: "root", byteSize: 150, itemCount: 2)
    let root = await index.node(id: "root")
    XCTAssertEqual(root?.byteSize, 150)
    XCTAssertEqual(root?.itemCount, 2)
}

func testChildrenSortedBySizeDescending() async {
    let index = ScanIndex()
    // insert root + two files sizes 10 and 99
    let kids = await index.children(of: "root")
    XCTAssertEqual(kids.map(\.id), ["big", "small"])
}

func testTypeTotalsByExtension() async {
    let index = ScanIndex()
    // two .png totaling 300, one .mov 1000 under root
    let totals = await index.typeTotals(scopeRootId: "root")
    XCTAssertEqual(totals.first?.fileExtension, "mov")
    XCTAssertEqual(totals.first?.bytes, 1000)
}

func testRemoveUpdatesParentTotals() async {
    // after remove of child, parent size/count decrease; type totals update
}
```

- [ ] **Step 2: Run — expect FAIL**

```bash
swift test --filter ScanIndexTests
```

- [ ] **Step 3: Implement ScanIndex**

Use private dictionaries:

```swift
actor ScanIndex {
    private var nodes: [String: StorageNode] = [:]
    private var childrenByParent: [String: [String]] = [:] // parent key "" for root
    private var typeBytes: [String: [String: (count: Int, bytes: Int64)]] = [:] // location or scope later

    func apply(batch: [StorageNode], generation: UInt64) async {
        for var n in batch {
            n.scanGeneration = generation
            nodes[n.id] = n
            let key = n.parentId ?? ""
            var list = childrenByParent[key] ?? []
            if !list.contains(n.id) { list.append(n.id) }
            childrenByParent[key] = list
            if n.nodeKind == .file {
                // bump type totals for extension
            }
        }
        // re-sort affected parent keys
    }
    // ...
}
```

Folder sizes: either scanner sends finalized sizes, or `reaggregateAncestors` sums children bottom-up after batches. Implement **bottom-up reaggregate** for correctness after deletes.

- [ ] **Step 4: Run — expect PASS**

```bash
swift test --filter ScanIndexTests
swift test --filter TypeTotalsTests
```

- [ ] **Step 5: Commit**

```bash
git commit -am "feat: ScanIndex tree aggregation and type totals"
```

---

### Task 4: SQLite persistence for index

**Files:**
- Create: `Sources/Cistilka/Index/SQLiteStore.swift`
- Create: `Tests/CistilkaTests/SQLiteStoreTests.swift`
- Modify: `Package.swift` if adding GRDB.swift dependency; otherwise use `SQLite3` system library

**Interfaces:**
- Consumes: `StorageNode`, `ScanLocation`
- Produces:
  - `actor SQLiteStore`
    - `init(url: URL) throws`
    - `func save(nodes: [StorageNode]) async throws`
    - `func load(locationId: UUID) async throws -> [StorageNode]`
    - `func delete(locationId: UUID) async throws`
  - On scan complete: flush index for location
  - On app launch: optional load last scan for selected location

**Recommendation:** Prefer **GRDB** for maintainability:

```swift
.package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0")
```

- [ ] **Step 1: Failing round-trip test** with temp file URL  
- [ ] **Step 2: Implement schema**

```sql
CREATE TABLE nodes (
  id TEXT NOT NULL,
  location_id TEXT NOT NULL,
  parent_id TEXT,
  name TEXT NOT NULL,
  node_kind TEXT NOT NULL,
  logical_path TEXT NOT NULL,
  byte_size INTEGER NOT NULL,
  item_count INTEGER NOT NULL,
  file_extension TEXT NOT NULL,
  is_package INTEGER NOT NULL,
  permissions_state TEXT NOT NULL,
  modified_at REAL,
  remote_id TEXT,
  scan_generation INTEGER NOT NULL,
  PRIMARY KEY (location_id, id)
);
CREATE INDEX idx_nodes_parent ON nodes(location_id, parent_id);
```

- [ ] **Step 3: Tests PASS + commit**

```bash
git commit -am "feat: SQLite persistence for scan nodes"
```

---

### Task 5: ScanSource protocol + LocalDiskSource

**Files:**
- Create: `Sources/Cistilka/Scanner/ScanSource.swift`
- Create: `Sources/Cistilka/Scanner/LocalDiskSource.swift`
- Create: `Tests/CistilkaTests/LocalDiskSourceTests.swift`

**Interfaces:**
- Consumes: `StorageNode`, `ScanProgress`
- Produces:

```swift
protocol ScanSource: Sendable {
    var supportsTrash: Bool { get }
    func enumerate(
        location: ScanLocation,
        generation: UInt64,
        onBatch: @Sendable ([StorageNode]) async -> Void,
        onProgress: @Sendable (ScanProgress) async -> Void
    ) async throws
    func trash(nodes: [StorageNode]) async throws -> [RemovalResult]
    func reveal(node: StorageNode) async throws
    func resolveDisplayPath(node: StorageNode) -> String
}
```

`LocalDiskSource`:
- Recursive walk with `FileManager`
- Prefer allocated size via `URL.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileSizeKey, .isDirectoryKey, .isPackageKey, .contentModificationDateKey, .isSymbolicLinkKey])`
- Do **not** follow symlinks
- Treat packages as leaves when `isPackage == true`
- On permission error: emit node with `permissionsState = .denied` and continue
- Worker concurrency: `TaskGroup` limited to 6 concurrent directory listings
- `trash`: `FileManager.trashItem(at:resultingItemURL:)`
- `reveal`: `NSWorkspace.shared.activateFileViewerSelecting`

- [ ] **Step 1: Failing integration test**

```swift
func testScansTempTreeSizes() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let f = root.appendingPathComponent("a.bin")
    try Data(repeating: 1, count: 4096).write(to: f)

    let source = LocalDiskSource()
    let loc = ScanLocation(id: UUID(), sourceKind: .local, displayName: "t", rootRef: root.path, accountId: nil, lastScannedAt: nil, scanState: .idle)
    var nodes: [StorageNode] = []
    try await source.enumerate(location: loc, generation: 1, onBatch: { nodes.append(contentsOf: $0) }, onProgress: { _ in })
    XCTAssertTrue(nodes.contains { $0.name == "a.bin" && $0.byteSize >= 4096 })
}
```

- [ ] **Step 2: Implement LocalDiskSource**  
- [ ] **Step 3: Test trash moves file out of original path**  
- [ ] **Step 4: PASS + commit**

```bash
git commit -am "feat: LocalDiskSource scan and trash"
```

---

### Task 6: ScanCoordinator + LocationStore

**Files:**
- Create: `Sources/Cistilka/Scanner/ScanCoordinator.swift`
- Create: `Sources/Cistilka/Support/LocationStore.swift`
- Create: `Tests/CistilkaTests/ScanCoordinatorTests.swift`
- Modify: `Sources/Cistilka/App/AppModel.swift`

**Interfaces:**
- Consumes: `ScanSource`, `ScanIndex`, `SQLiteStore`
- Produces:

```swift
@MainActor
final class ScanCoordinator {
    func startScan(location: ScanLocation, source: any ScanSource, mode: ScanMode) async
    func cancel(locationId: UUID)
    var progress: [UUID: ScanProgress] { get }
}

enum ScanMode: Sendable {
    case full
    case refreshSubtree(nodeId: String)
}
```

Behavior:
- Spawn `Task.detached` (or unstructured Task with utility priority) for enumerate
- Apply batches to `ScanIndex` every ≤ 100ms coalesced
- On full scan: increment generation; `discardGeneration` for old
- On complete: `scanState = .complete`, persist via SQLite, set `lastScannedAt`
- On cancel: cooperative cancel; state `.cancelled` with partial data kept
- Cap 2 concurrent location scans

`LocationStore`: load/save `[ScanLocation]` JSON in Application Support `locations.json`.

- [ ] **Step 1: Test** coordinator applies batches into index from a fake `ScanSource`  
- [ ] **Step 2: Test** cancel stops further batches  
- [ ] **Step 3: Implement + PASS + commit**

```bash
git commit -am "feat: ScanCoordinator and location persistence"
```

---

### Task 7: Main UI shell — sidebar, tree, inspector, progress

**Files:**
- Create/Modify: `UI/ContentView.swift`, `SidebarView.swift`, `TreeTableView.swift`, `InspectorView.swift`, `EmptyStateView.swift`, `ProgressHeaderView.swift`
- Modify: `AppModel.swift` to own `ScanIndex` handle, selection, breadcrumbs, filter extension

**Interfaces:**
- Consumes: `ScanIndex`, `ScanCoordinator`, `LocationStore`
- Produces: interactive UI for local scans end-to-end

UI requirements (spec §6):
- Sidebar sections: This Mac / Cloud / SSH / Scans
- Tree columns: Name, Items, Size, % Parent (bar)
- Default sort size desc
- Breadcrumbs for focused root
- Inspector: type totals + selection details
- Empty state CTAs: Scan Home, Scan volume…, Connect Google, Connect OneDrive, Add SSH
- Toolbar: Add Location, Rescan, Stop, Search

Implementation notes:
- Prefer bridged `NSOutlineView` if SwiftUI `Table` performance is poor; start with SwiftUI `List` hierarchical or `Table` and switch if needed
- Observe index via `AppModel` polling/`AsyncStream` of snapshots published on MainActor at ≤ 15 Hz during scan
- Search filters visible names client-side

- [ ] **Step 1: Wire Scan Home** → location for `NSHomeDirectory()`, start scan, stream tree  
- [ ] **Step 2: Manual run** `swift build` and `Scripts/compile_and_run.sh`  
- [ ] **Step 3: Commit**

```bash
git commit -am "feat: sidebar, tree table, inspector UI for local scans"
```

---

### Task 8: RevealService + RemovalService (local) + confirm sheet

**Files:**
- Create: `Support/RevealService.swift`
- Create: `Removal/RemovalService.swift`
- Create: `UI/ConfirmTrashSheet.swift`
- Create: `Tests/CistilkaTests/RemovalServiceTests.swift`

**Interfaces:**

```swift
struct RevealService {
    @MainActor static func reveal(node: StorageNode, source: any ScanSource) async throws
}

@MainActor
final class RemovalService {
    func requestTrash(nodes: [StorageNode], source: any ScanSource) // shows confirm
    func performTrash(nodes: [StorageNode], source: any ScanSource) async -> [RemovalResult]
}
```

Confirm sheet copy: “Move N items (SIZE) to Trash?”  
On success: `ScanIndex.remove`, `reaggregateAncestors`, refresh type totals.  
Keyboard ⌘⌫ and context menu call same path.

- [ ] **Step 1: Unit test** `RemovalService` with mock source records trash calls and index updates  
- [ ] **Step 2: Implement + PASS**  
- [ ] **Step 3: Commit**

```bash
git commit -am "feat: reveal in Finder and trash with confirmation"
```

---

### Task 9: PermissionCoach + diagnostics

**Files:**
- Create: `Support/PermissionCoach.swift`
- Create: `Support/DiagnosticsLog.swift`
- Create: `UI/PermissionCoachSheet.swift` (or embed in ContentView)
- Create: `Tests/CistilkaTests/PermissionCoachTests.swift`

**Interfaces:**
- After scan, if denied node count > threshold (e.g. 50) or home scan bytes suspiciously low, set `needsFDACoach = true`
- Sheet explains FDA; button opens `x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles` (or macOS 13+ Settings URL; use best available and fallback to copy instructions)
- Re-check: try reading a known protected path; update UI
- `DiagnosticsLog` actor appends timestamped lines; export to temp file

- [ ] **Step 1: Test** threshold logic pure function  
- [ ] **Step 2: Implement UI coach**  
- [ ] **Step 3: Commit**

```bash
git commit -am "feat: Full Disk Access coach and diagnostics log"
```

---

### Task 10: Keychain + PKCE + OAuthConfig

**Files:**
- Create: `Auth/KeychainStore.swift`
- Create: `Auth/PKCE.swift`
- Create: `Auth/OAuthConfig.swift`
- Create: `Config/OAuth.example.plist`
- Create: `Tests/CistilkaTests/PKCETests.swift`
- Modify: `.gitignore` (ensure OAuth.plist ignored)

**Interfaces:**

```swift
struct OAuthConfig: Sendable {
    var googleClientID: String?
    var googleRedirectURI: String?
    var microsoftClientID: String?
    var microsoftRedirectURI: String?
    static func load() -> OAuthConfig // from bundle resource or Config path
}

enum PKCE {
    static func makeVerifier() -> String
    static func challenge(for verifier: String) -> String // S256 base64url
}

actor KeychainStore {
    func set(_ data: Data, account: String, service: String) throws
    func get(account: String, service: String) throws -> Data?
    func delete(account: String, service: String) throws
}
```

Example plist keys: `GoogleClientID`, `GoogleRedirectURI`, `MicrosoftClientID`, `MicrosoftRedirectURI`.

- [ ] **Step 1: PKCE tests** — challenge is deterministic for fixed verifier; verifier length ≥ 43  
- [ ] **Step 2: Implement + PASS**  
- [ ] **Step 3: Commit**

```bash
git commit -am "feat: Keychain, PKCE, and OAuth config loading"
```

---

### Task 11: Google Drive source (auth + list + trash)

**Files:**
- Create: `Auth/GoogleOAuthClient.swift`
- Create: `Auth/AuthStore.swift` (shared multi-account)
- Create: `Scanner/GoogleDriveSource.swift`
- Create: `Tests/CistilkaTests/GoogleDriveSourceTests.swift` (URLProtocol mock)
- Modify: Info.plist URL scheme for redirect
- Modify: UI connect Google flow

**Interfaces:**
- `GoogleOAuthClient.signIn() async throws -> OAuthTokens` using `ASWebAuthenticationSession`
- Scopes: list + trash capable (document in UI); refresh with offline token
- `AuthStore` saves refresh token in Keychain per account email
- `GoogleDriveSource.enumerate`: Drive API v3 files.list by parent, `trashed=false`, paginate
- Map folders vs files; size Int64; remoteId = file id
- `trash`: PATCH files with `trashed=true`
- `reveal`: open `https://drive.google.com/file/d/{id}/view` or folder URL; if CloudStorage path exists, prefer Finder

Mock test:

```swift
// URLProtocol stub returns fixed JSON list; assert nodes count and names
```

- [ ] **Step 1: Mock list test FAIL → implement parser + source**  
- [ ] **Step 2: Mock trash test**  
- [ ] **Step 3: Wire UI Sign in + location row**  
- [ ] **Step 4: Commit**

```bash
git commit -am "feat: Google Drive OAuth, scan, and trash"
```

Look up current Google OAuth desktop + PKCE and Drive API fields at implement time (`https://developers.google.com/drive/api/reference/rest/v3/files/list`).

---

### Task 12: OneDrive source (auth + list + trash)

**Files:**
- Create: `Auth/MicrosoftOAuthClient.swift`
- Create: `Scanner/OneDriveSource.swift`
- Create: `Tests/CistilkaTests/OneDriveSourceTests.swift`
- Modify: AuthStore, UI, Info.plist scheme if needed

**Interfaces:**
- Microsoft identity platform auth code + PKCE
- Scopes: `offline_access User.Read Files.ReadWrite`
- Graph: `GET /me/drive/root/children` and `GET /me/drive/items/{id}/children`
- Trash: `DELETE /me/drive/items/{id}` (recycle bin — verify docs at implement time)
- Reveal: `webUrl` field

- [ ] **Step 1: Mock Graph children JSON → nodes**  
- [ ] **Step 2: Mock delete → movedToTrash**  
- [ ] **Step 3: UI connect OneDrive**  
- [ ] **Step 4: Commit**

```bash
git commit -am "feat: OneDrive OAuth, scan, and recycle-bin trash"
```

Docs to verify: Microsoft Graph driveItem delete / recycle bin behavior.

---

### Task 13: SSH profiles + SFTP source

**Files:**
- Create: `Scanner/SSHSource.swift`
- Create: `UI/SSHProfileSheet.swift`
- Create: `Models/SSHProfile.swift`
- Create: `Tests/CistilkaTests/PathNormalizationTests.swift`
- Modify: LocationStore / Keychain for SSH secrets
- Package.swift: add SFTP dependency (prefer Citadel or similar maintained SPM package; if blocked, document fallback)

**Interfaces:**

```swift
struct SSHProfile: Codable, Identifiable, Sendable {
    var id: UUID
    var displayName: String
    var host: String
    var port: Int
    var username: String
    var authMethod: SSHAuthMethod // password | privateKey
    var remotePath: String
    var remoteTrashPath: String?
    // secrets NOT in this struct — Keychain by profile id
}
```

- TOFU host key storage in Keychain/App Support
- Enumerate via SFTP readdir; low concurrency (2–4)
- Trash: rename into `remoteTrashPath` if set; else `RemovalService` shows permanent delete confirm requiring typing `DELETE`
- Reveal: pasteboard path + optional Terminal open
- Normalize remote paths (absolute, collapse `//`, resolve `.`)

- [ ] **Step 1: Path normalization unit tests**  
- [ ] **Step 2: Implement SSHSource with dependency**  
- [ ] **Step 3: UI Add SSH + test connection**  
- [ ] **Step 4: Commit**

```bash
git commit -am "feat: SSH/SFTP scan profiles and safe remove"
```

---

### Task 14: Drag-to-trash bar + multi-select polish

**Files:**
- Create: `UI/TrashDropBar.swift`
- Modify: `TreeTableView.swift`, `RemovalService.swift`, `ContentView.swift`

**Interfaces:**
- Bottom bar always available when selection non-empty or during drag
- Drop destination accepts `StorageNode` drag payload (UTType or internal pasteboard type)
- Calls **same** `RemovalService.requestTrash` as menu/⌘⌫
- Mixed sources: group confirm by sourceKind
- Disable drop for nodes with failed permission or unsupported

- [ ] **Step 1: Manual verification checklist in commit message**  
- [ ] **Step 2: Implement drop delegate + highlight states**  
- [ ] **Step 3: Commit**

```bash
git commit -am "feat: drag-and-drop trash bar for multi-select cleanup"
```

---

### Task 15: Preferences, accounts, performance polish, packaging

**Files:**
- Modify: `AccountsSettingsView.swift`
- Create: `UI/GeneralSettingsView.swift`
- Modify: `ScanCoordinator` parallelism preference
- Modify: `LocalDiskSource` package expand preference
- Modify: `Scripts/package_app.sh`, `version.env`
- Update: `README.md` with build/run/OAuth setup

**Preferences:**
- Default scan roots
- Treat packages as leaf (default true)
- Parallelism: Gentle (2) / Default (6) / Aggressive (12) for local workers
- Clear cached scans (delete SQLite rows + memory)
- Accounts list: sign out Google/Microsoft, edit/delete SSH

**Packaging:**
- Non-sandbox Info.plist keys: network client usage description if required; LSMinimumSystemVersion 14.0
- URL schemes for OAuth redirects
- `Scripts/compile_and_run.sh` builds .app and launches
- README: FDA steps, OAuth.plist setup, SSH notes

- [ ] **Step 1: `swift test` all green**  
- [ ] **Step 2: Package and launch smoke**  
- [ ] **Step 3: Commit**

```bash
git commit -am "feat: settings, accounts, packaging, and performance prefs"
```

---

### Task 16: End-to-end verification checklist (no new features)

**Files:** none required (docs only if gaps found)

- [ ] **Step 1: Run full automated suite**

```bash
swift test
```

Expected: all PASS

- [ ] **Step 2: Manual checklist (tick in PR/notes)**

1. Scan Home without UI freeze; progress updates; Stop leaves Partial  
2. Tree columns size/items/% parent correct on a known fixture folder  
3. Type totals match folder scope  
4. Reveal in Finder selects file  
5. Trash local file appears in Trash; index updates  
6. FDA coach appears when denials high (simulate if needed)  
7. Google: sign-in (with real OAuth.plist), scan My Drive, trash one test file  
8. OneDrive: sign-in, scan, trash test file to recycle bin  
9. SSH: key auth to a test host, scan path, remove via remote trash path  
10. Drag multi-select to trash bar with confirm  
11. App relaunch loads saved locations (and cached scan if implemented)

- [ ] **Step 3: Fix any P0 bugs found; commit fixes**  
- [ ] **Step 4: Final commit if docs updated**

```bash
git commit -am "test: complete v1 verification checklist"
```

---

## Spec coverage matrix

| Spec area | Tasks |
|-----------|-------|
| Local scan + dense tree + % parent | 2–7 |
| File type totals | 3, 7 |
| Reveal in Finder | 8 |
| Trash local | 5, 8, 14 |
| Non-blocking scan / cancel | 6 |
| FDA / permissions | 5, 9 |
| Google Drive | 10–11 |
| OneDrive | 10, 12 |
| SSH | 13 |
| Drag to trash | 14 |
| OAuth config / Keychain | 10 |
| Hybrid non-sandbox packaging | 1, 15 |
| SQLite fast refresh | 4, 6 |
| Diagnostics | 9 |
| Settings / accounts | 15 |
| Success criteria §11 | 16 |

## Self-review notes

- No treemap/duplicates/daemon tasks (correctly out of scope)
- Types consistent: `ScanLocation`, `StorageNode`, `ScanSource`, `ScanIndex`, `RemovalResult` reused across tasks
- Prefer splitting `CistilkaCore` library if tests cannot import executable
- Verify Graph delete = recycle bin and Google trash API at implementation time against live docs
- SFTP library choice finalized in Task 13 based on SPM compatibility on macOS 14+

---

## Execution handoff

Plan complete and saved to `docs/superpowers/plans/2026-08-02-cistilka-implementation.md`.

**Two execution options:**

1. **Subagent-Driven (recommended)** — fresh subagent per task, review between tasks, fast iteration  
2. **Inline Execution** — execute tasks in this session with checkpoints  

Which approach?
