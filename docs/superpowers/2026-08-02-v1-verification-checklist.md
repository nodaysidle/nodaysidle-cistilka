# Cistilka v1 — End-to-end verification checklist

**Date:** 2026-08-02  
**Package identity:** `Cistilka` / `com.nodaysidle.cistilka` / `0.1.0` (build 1)  
**Scope:** Task 16 — automated verification + manual release notes (design §11)

---

## Automated results (2026-08-02)

| Check | Command | Result |
|-------|---------|--------|
| Unit + integration suite | `swift test` | **PASS** — 109 tests, 0 failures (~1.5s) |
| Debug build | `swift build` | **PASS** |
| Release package | `./Scripts/package_app.sh release` | **PASS** — `Cistilka.app` created |

### Packaging smoke (post-`package_app.sh`)

| Property | Observed |
|----------|----------|
| Bundle id | `com.nodaysidle.cistilka` |
| Version / build | `0.1.0` / `1` |
| `LSMinimumSystemVersion` | `14.0` |
| OAuth URL schemes | `com.nodaysidle.cistilka`, `msauth.com.nodaysidle.cistilka` |
| Local network usage string | Present (`NSLocalNetworkUsageDescription`) |
| Code signature | Ad-hoc (`flags=0x2`) |
| Executable | `Cistilka.app/Contents/MacOS/Cistilka` (arm64) |

### Suite breakdown (`swift test`)

| Suite | Count | Failures |
|-------|------:|---------:|
| AppPreferencesTests | 5 | 0 |
| ByteFormatTests | 3 | 0 |
| GoogleDriveSourceTests | 9 | 0 |
| LocalDiskSourceTests | 8 | 0 |
| OneDriveSourceTests | 10 | 0 |
| PKCETests | 4 | 0 |
| PathNormalizationTests | 9 | 0 |
| PermissionCoachTests | 7 | 0 |
| RemovalServiceTests | 14 | 0 |
| SQLiteStoreTests | 4 | 0 |
| SSHSourceTests | 4 | 0 |
| ScanCoordinatorTests | 8 | 0 |
| ScanIndexTests | 10 | 0 |
| SmokeTests | 1 | 0 |
| StorageNodeTests | 5 | 0 |
| TreeNameFilterTests | 2 | 0 |
| TypeTotalsTests | 6 | 0 |
| **Total** | **109** | **0** |

**Notes:**

- `LocalDiskSourceTests.testTrashMovesFileOutOfOriginalPath` logs benign CoreData/XPC noise under XCTest; test still **passed**.
- Cloud/SSH coverage is mock-based (URLProtocol / fake SFTP); **no live network credentials** used in CI/automated run.
- No P0 defects found from the automated suite; no code fixes required for Task 16.

---

## Manual checklist (requires human / live env)

Tick in PR notes or release sign-off. **Not** run in this automated Task 16 pass.

| # | Criterion (plan Task 16 / design §11) | Status | Notes |
|---|----------------------------------------|--------|-------|
| 1 | Scan Home without UI freeze; progress updates; Stop leaves **Partial** | ⬜ Manual | Needs interactive app run |
| 2 | Tree columns size / items / % parent correct on known fixture folder | ⬜ Manual | Unit coverage exists (`ScanIndex`, `% parent`); UI layout visual check still needed |
| 3 | Type totals match folder scope | ⬜ Manual | Unit: `TypeTotalsTests` green; inspector UI visual check |
| 4 | Reveal in Finder selects file | ⬜ Manual | Local only |
| 5 | Trash local file → appears in Trash; index updates | ⬜ Manual | Integration: `LocalDiskSource` + `RemovalService` trash tests green |
| 6 | FDA coach when denials high | ⬜ Manual | Unit: `PermissionCoachTests` green; needs real/restricted path |
| 7 | **Google:** sign-in (`Config/OAuth.plist`), scan My Drive, trash one test file | ⬜ Manual live | Needs real OAuth client + network |
| 8 | **OneDrive:** sign-in, scan, trash test file to recycle bin | ⬜ Manual live | Needs real Microsoft app + network |
| 9 | **SSH:** key auth to test host, scan path, remove via remote trash path | ⬜ Manual live | Needs host + key; permanent-delete path needs strong-confirm exercise |
| 10 | Drag multi-select to trash bar with confirm | ⬜ Manual | UI / NSItemProvider path |
| 11 | App relaunch loads saved locations (and cached scan if implemented) | ⬜ Manual | Unit: location store + SQLite round-trip green |

### Manual environment prerequisites

- macOS 14+; grant **Full Disk Access** to `Cistilka.app` for deep Home/volume scans
- Copy `Config/OAuth.example.plist` → gitignored `Config/OAuth.plist` with real Google/Microsoft client IDs and redirect URIs matching packaged URL schemes
- SSH: reachable host, key (or password) profile, optional remote trash directory for non-permanent remove
- Prefer ad-hoc or Developer ID signed app from `./Scripts/package_app.sh release` for FDA/OAuth session behavior close to release

---

## Design §11 success criteria mapping

| Success criterion | Automated | Manual remaining |
|-------------------|-----------|------------------|
| Scan Home/large volume without UI freeze | Partial (coordinator cancel/batch tests) | Yes — Home scan perf |
| Dense tree size/items/% parent; type totals match scope | Yes (index, % parent, type totals) | Yes — visual |
| Reveal in Finder (local / mirrored cloud) | No UI automation | Yes |
| Drag/menu trash → Trash/recycle (local + cloud) | Yes (local trash + mock Google/OneDrive trash + RemovalService) | Yes — drag + live cloud |
| Google / OneDrive / SSH first-class + sign-in/profiles | Yes (source + OAuth parse/PKCE mocks; SSH mock) | Yes — live auth |
| FDA and OAuth failures recoverable without restart | Partial (coach thresholds; missing OAuth.plist does not crash) | Yes — live FDA/OAuth expiry banner |

---

## Conclusion

- **Automated gate for v1:** **GREEN** (109/109, build OK, package smoke OK).
- **P0 from suite:** none.
- **Release-ready** only after manual rows 1–11 (especially live Google, OneDrive, SSH, FDA) are ticked on a developer machine.
