# Task 13 review brief — SSH profiles + SFTP source

## Scope

Review implementation of plan Task 13 (`docs/superpowers/plans/2026-08-02-cistilka-implementation.md` § Task 13) and design §5.5 against HEAD after base `4d3e87470` (OneDrive complete).

## Range

- **Base:** `4d3e874705e0df7b562714c0cdda4a29154037af` — feat: OneDrive OAuth, scan, and recycle-bin trash
- **Head:** `cf58d305ce867fc7a5578a36e1b56a139e3a0ad0` — feat: SSH/SFTP scan profiles and safe remove
- **Diff path:** `.superpowers/sdd/review-4d3e87470..cf58d305.diff` (or matching `review-4d3e87470..*.diff`)

## Must checks

1. **Path normalize tests** — unit coverage for absolute paths, collapse `//`, resolve `.` / `..`
2. **Trash** — rename into `remoteTrashPath` when set; else permanent delete only after strong confirm (type `DELETE`)
3. **Keychain secrets** — passwords/keys not in `SSHProfile` / JSON profiles; Keychain (or equivalent secure store)
4. **ScanSource** — `SSHSource` implements `ScanSource` and is wired into scan/trash/reveal
5. **No free-form shell** — in-process SFTP (Citadel/NIOSSH); UI paths must not drive free-form `ssh`/`sftp` shell

## Expected artifacts (plan)

- `Models/SSHProfile.swift`, `Scanner/SSHSource.swift`, `UI/SSHProfileSheet.swift`
- Path + SSH tests under `Tests/CistilkaTests/`
- Credential store / Keychain integration; Package.swift SFTP dependency
- RemovalService / ConfirmTrashSheet strong confirm for SSH without trash path

## Mode

Read-only review. Verdict: **Approved** | **Needs fixes**.
