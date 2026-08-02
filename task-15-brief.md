# Task 15 review brief — Preferences, accounts, performance polish, packaging

## Scope

Review implementation of plan Task 15 (`docs/superpowers/plans/2026-08-02-cistilka-implementation.md` § Task 15) and design §6.7 / packaging notes against HEAD after base `6282b15f2` (drag-to-trash complete).

## Range

- **Base:** `6282b15f2` — feat: drag-and-drop trash bar for multi-select cleanup
- **Head:** `87a9e233d` (or workspace HEAD after settings/packaging) — feat: settings, accounts, packaging, and performance prefs
- **Diff path:** `.superpowers/sdd/review-6282b15f2..87a9e233d.diff` (or matching `review-6282b15f2..*.diff`)

## Must checks

1. **Preferences** — Settings → General: default scan roots, treat packages as leaf (default true), parallelism Gentle(2)/Default(6)/Aggressive(12) for local workers, clear cached scans (SQLite + memory), follow system appearance. Prefs drive `LocalDiskSource` package expand and worker count and `ScanCoordinator` concurrency.
2. **Accounts** — Settings → Accounts: list/sign out Google & Microsoft; edit/delete SSH profiles; OAuth setup guidance without secrets in git.
3. **Packaging** — Non-sandbox; `LSMinimumSystemVersion` 14.0; network usage description if needed; OAuth URL schemes in Info.plist + `package_app.sh`; `compile_and_run.sh` builds .app and launches; `version.env` identity; README covers FDA, OAuth.plist, SSH, prefs.

## Expected artifacts (plan)

- Create: `UI/GeneralSettingsView.swift` (+ prefs support as needed)
- Modify: `AccountsSettingsView.swift`
- Modify: `ScanCoordinator` parallelism preference
- Modify: `LocalDiskSource` package expand preference
- Modify: `Scripts/package_app.sh`, `version.env`
- Update: `README.md` with build/run/OAuth setup

## Mode

Read-only review. Verdict: **Approved** | **Needs fixes**.
