# AGENTS.md — Cistilka

## Project

Cistilka is a native macOS disk/cloud space analyzer. Stack: Swift 6, SwiftUI, SwiftPM executable app (macOS 14+), non-sandbox first.

## Read first

1. This file
2. `docs/superpowers/specs/2026-08-02-cistilka-design.md`
3. `docs/superpowers/plans/2026-08-02-cistilka-implementation.md`
4. `version.env` for packaging identity

## Global constraints

- App name: **Cistilka**; bundle id: `com.nodaysidle.cistilka`
- Swift tools **6.2+**, platform **macOS 14+**, Swift **6** language mode
- Non-sandbox Developer ID first; no App Sandbox entitlement in v1
- Local/cloud remove = **Trash only**
- SSH permanent delete only after strong confirm when no remote trash
- OAuth: public native clients + PKCE; secrets in gitignored `Config/OAuth.plist`
- No treemap, no duplicate finder, no background daemon in v1
- No disk I/O on MainActor; UI updates batched ≤ ~15 Hz during scan
- TDD: failing test first, implement, pass, commit

## Layout

```text
Package.swift
Sources/Cistilka/          # executable target (@main + UI + domain)
Tests/CistilkaTests/
Scripts/package_app.sh
Scripts/compile_and_run.sh
version.env
```

If `@testable import` ever fails against the executable, split a `CistilkaCore` library and keep a thin `Cistilka` executable.

## Commands

```bash
swift test
swift build
./Scripts/package_app.sh release
./Scripts/compile_and_run.sh
```

## Packaging notes

- `Sources/Cistilka/Resources/Info.plist` is packaging metadata (excluded from SwiftPM resource processing).
- `package_app.sh` sources `version.env` (`APP_NAME`, `BUNDLE_ID`, `VERSION`, `BUILD_NUMBER`).
- Ad-hoc sign by default (`SIGNING_MODE=adhoc` or empty `APP_IDENTITY`).

## Do not

- Stage unrelated monorepo projects when committing
- Commit real OAuth secrets
- Permanent-delete local/Google/OneDrive items
