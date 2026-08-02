# Task 15 review report — Preferences, accounts, performance polish, packaging

| Field | Value |
|-------|--------|
| Task | 15 — Preferences, accounts, performance polish, packaging |
| Base | `6282b15f2` (drag-to-trash) |
| Head | `87a9e233d` / workspace HEAD (settings/packaging; packaged app `GitCommit=87a9e233d`) |
| Diff | `.superpowers/sdd/review-6282b15f2..87a9e233d.diff` |
| Mode | Read-only |
| **Verdict** | **Needs fixes** |

---

## Summary

Task 15 delivers General + Accounts Settings, UserDefaults-backed scan prefs (packages leaf, Gentle/Default/Aggressive workers, clear cache), wired `LocalDiskSource` / `ScanCoordinator` knobs, OAuth URL schemes and `LSMinimumSystemVersion` 14.0 packaging, `compile_and_run.sh`, and a solid README (FDA / OAuth / SSH / prefs).

**Blocking gap:** default scan roots are stored and edited in Settings, and both the UI copy and README claim they are “quick-start targets,” but **nothing in the scan/empty-state/sidebar UX reads `resolvedDefaultRoots`**. `includeHomeInDefaults` is likewise unused outside the prefs model/tests. That fails must-check 1 for functional default roots.

Accounts and packaging must-checks pass.

---

## Must-check results

### 1. Preferences — PARTIAL (blocking)

Design §6.7: *“Default roots, package expand, scan parallelism, accounts, clear cached scans, follow system appearance.”*  
Plan: Gentle(2) / Default(6) / Aggressive(12) local workers; clear SQLite + memory.

| Item | Status | Evidence |
|------|--------|----------|
| Settings → General UI | Pass | `CistilkaApp` Settings `TabView` → `GeneralSettingsView` |
| Treat packages as leaf (default true) | Pass | `AppPreferences.treatPackagesAsLeaf` default true; toggle; `LocalDiskSource` leaf/package walk; tests |
| Parallelism 2 / 6 / 12 local workers | Pass | `ScanParallelism.localWorkers`; `makeLocalDiskSource` → `maxConcurrentListings`; picker + `applyScanParallelismPreference` |
| Coordinator concurrency scales with preset | Pass | `maxConcurrentLocations` 1/2/4; `ScanCoordinator.setMaxConcurrent` |
| Clear cached scans (SQLite + memory) | Pass | `clearCachedScans` → `store.deleteAll()`, `index.removeAll()`, stop scans, reset location scan state; confirm dialog |
| Follow system appearance | Pass | Caption only (no forced color scheme); acceptable |
| Prefs tests | Pass | `AppPreferencesTests` suite |
| **Default scan roots usable as targets** | **Fail** | Prefs store `defaultRootPaths` / `includeHomeInDefaults` / `resolvedDefaultRoots`, editable in General Settings; **no consumer** in `EmptyStateView`, `SidebarView`, or `AppModel` scan actions. Empty state only hardcodes `scanHome()` + `scanVolume()`. |

Wiring that works:

```122:128:Sources/Cistilka/Support/AppPreferences.swift
    func makeLocalDiskSource() -> LocalDiskSource {
        LocalDiskSource(
            treatPackagesAsLeaf: treatPackagesAsLeaf,
            maxConcurrentListings: scanParallelism.localWorkers
        )
    }
```

```190:216:Sources/Cistilka/App/AppModel.swift
    func applyScanParallelismPreference() {
        coordinator?.setMaxConcurrent(preferences.scanParallelism.maxConcurrentLocations)
    }

    func clearCachedScans() {
        Task {
            // stopScan… store.deleteAll(); index.removeAll(); reset scanState…
        }
    }
```

Local scans/trash use `preferences.makeLocalDiskSource()` so package + worker prefs apply on next scan.

**Required fix (minimal):** drive quick-start UI from `preferences.resolvedDefaultRoots` (empty state and/or sidebar), e.g. one button per root calling `startLocalScan` (or equivalent public API). Honor `includeHomeInDefaults` via that list (not a permanent hard-coded Home-only path that ignores prefs).

### 2. Accounts — PASS

| Behavior | Evidence |
|----------|----------|
| Google list + Sign Out | `AccountsSettingsView` → `signOutGoogle`; tokens via `AuthStore` |
| Microsoft list + Sign Out | `signOutMicrosoft` |
| Connect disabled if OAuth unconfigured | `isGoogleOAuthConfigured` / `isMicrosoftOAuthConfigured` |
| SSH list, Edit, Delete, Add | `editSSH` / `deleteSSHProfile` / `addSSH`; Keychain note in UI |
| OAuth setup copy + reload | `Config/OAuth.plist` guidance; redirect schemes documented; `reloadOAuthConfig` |
| No secrets in git | `OAuth.example.plist` only; real plist gitignored per AGENTS/README |

### 3. Packaging — PASS

| Requirement | Status | Evidence |
|-------------|--------|----------|
| Non-sandbox | Pass | Generated entitlements empty; no App Sandbox key; AGENTS non-sandbox first |
| `LSMinimumSystemVersion` 14.0 | Pass | `Resources/Info.plist`, `package_app.sh` (`MACOS_MIN_VERSION` default 14.0), packaged app |
| Network usage description | Pass | `NSLocalNetworkUsageDescription` (LAN SSH) in source + packaged Info.plist |
| OAuth URL schemes | Pass | `com.nodaysidle.cistilka`, `msauth.com.nodaysidle.cistilka` in Resources Info.plist and `package_app.sh` CFBundleURLTypes; matches `OAuth.example.plist` |
| `version.env` identity | Pass | `APP_NAME=Cistilka`, `BUNDLE_ID=com.nodaysidle.cistilka`, `VERSION`, `BUILD_NUMBER` |
| `package_app.sh` | Pass | sources `version.env`, builds, lipo optional, copies SwiftPM bundles, ad-hoc sign |
| `compile_and_run.sh` | Pass | kill → package release → `open` .app; optional `--test` |
| README | Pass | build/test/package, FDA steps, OAuth.plist setup, SSH notes, prefs table |
| Platform / Swift 6 | Pass | `Package.swift` macOS 14, tools 6.2, language mode v6 |

Packaged sample (`Cistilka.app/Contents/Info.plist`): `GitCommit` `87a9e233d`, min 14.0, URL schemes present.

---

## Plan / design coverage

| Plan / design item | Status |
|--------------------|--------|
| Create `UI/GeneralSettingsView.swift` | Done |
| Modify `AccountsSettingsView` | Done |
| `ScanCoordinator` parallelism preference | Done |
| `LocalDiskSource` package expand preference | Done (+ worker count) |
| `Scripts/package_app.sh`, `version.env` | Done |
| README build/run/OAuth/FDA/SSH | Done |
| Default scan roots | **Incomplete** (storage + Settings only) |
| Treat packages as leaf default true | Done |
| Parallelism Gentle/Default/Aggressive | Done |
| Clear cached scans | Done |
| Accounts sign-out / SSH edit-delete | Done |
| System appearance | Done (implicit) |
| Non-sandbox packaging + OAuth schemes | Done |

---

## Blocking fixes

1. **Wire default scan roots into UX**  
   - Read `model.preferences.resolvedDefaultRoots` in empty-state (and optionally sidebar “This Mac” quick actions).  
   - Provide scan entry points for each path (display name = last path component; Home when path is `NSHomeDirectory()`).  
   - When `includeHomeInDefaults` is false and no custom roots, empty state should not pretend Home is a default (or still allow one-off Scan Volume / explicit Home if product wants — but prefs must have effect).  
   - Optional test: resolved roots list drives a pure helper used by UI (if extractable without heavy UI tests).

---

## Non-blocking notes (do not alone flip verdict)

1. **Package-leaf toggle mid-session** — takes effect on next local scan (source built per scan). Fine; no live rebind required.  
2. **`testMakeLocalDiskSourceUsesPrefs`** — asserts `treatPackagesAsLeaf` only; `maxConcurrentListings` is private (OK).  
3. **Clear cache** — does not reset `ScanCoordinator` generation maps; next full scan should still be correct.  
4. **`Resources/Info.plist` vs packaged root Info.plist** — package script generates `Contents/Info.plist` and also copies Resources into `Contents/Resources/` (extra Info.plist under Resources is harmless packaging metadata).  
5. **Appearance section** — informational only; no light/dark override (matches “follow system”).

---

## Verdict rationale

**Needs fixes** because must-check 1 requires **default scan roots** as a working preference (plan + design §6.7 + Settings/README copy), but the only production use of those values is storage/edit. Package/parallelism/accounts/packaging work is otherwise solid and can remain as-is while the roots wiring is fixed.

Re-review after wiring `resolvedDefaultRoots` into empty-state/sidebar scan actions; expect flip to **Approved** if that lands without regressions.
