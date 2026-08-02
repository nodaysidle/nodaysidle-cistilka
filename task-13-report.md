# Task 13 review report — SSH profiles + SFTP source

| Field | Value |
|-------|--------|
| Task | 13 — SSH profiles + SFTP source |
| Base | `4d3e874705e0df7b562714c0cdda4a29154037af` (OneDrive) |
| Head | `cf58d305ce867fc7a5578a36e1b56a139e3a0ad0` (SSH/SFTP) |
| Diff | `.superpowers/sdd/review-4d3e87470..cf58d305.diff` |
| Mode | Read-only |
| **Verdict** | **Approved** |

---

## Summary

Task 13 delivers a complete SSH/SFTP vertical: durable profiles without secrets, Keychain-backed credentials and TOFU host keys, Citadel in-process SFTP (`SSHSource: ScanSource`), path normalization with unit tests, trash via remote rename or gated permanent delete (`DELETE`), UI for Add SSH / test connection / accounts list, and wiring through `AppModel` + `RemovalService` + `ConfirmTrashSheet`. All five must-checks pass.

---

## Must-check results

### 1. Path normalize tests — PASS

`RemotePath.normalize` / `join` / `lastComponent` / `parent` in `Sources/Cistilka/Models/SSHProfile.swift`.

`Tests/CistilkaTests/PathNormalizationTests.swift` covers:

- empty → `/`
- relative → absolute
- collapse `//`
- resolve `.` and `..`
- root stability
- join edge cases
- `SSHProfile.rootRef` (default and non-default port forms)

Scan, trash, and Citadel bridge call `RemotePath.normalize` on remote paths.

### 2. Trash rename or DELETE confirm — PASS

| Path | Behavior | Evidence |
|------|----------|----------|
| `remoteTrashPath` set | SFTP `rename` into trash dir (unique dest name); best-effort `createDirectory` | `SSHSource.trash`, `testTrashRenamesIntoRemoteTrashPath` |
| No trash path | Fail unless `allowPermanentDelete`; recursive permanent remove when allowed | `testTrashWithoutPathBlockedUnlessAllowPermanent` |
| UI / RemovalService | `requiresPermanentDeleteConfirm` → sheet requires typing `DELETE`; confirm sets `allowPermanentDelete` | `RemovalService.requestTrash` / `confirmPending`, `ConfirmTrashSheet`, `RemovalServiceTests` SSH cases |

Permanent delete never runs from the default `scanSource` path (`allowPermanentDelete: false`).

### 3. Keychain secrets — PASS

- `SSHProfile` is metadata only (no password/key fields).
- `SSHSecrets` stored via `SSHCredentialStore.saveSecrets` → `KeychainStore` service `com.nodaysidle.cistilka.ssh.secrets`.
- Profiles JSON under Application Support (`ssh-profiles.json`).
- Host-key fingerprints in Keychain service `com.nodaysidle.cistilka.ssh.hostkeys` (TOFU).
- Diagnostics log only host/user/path-style messages; no secret material.

### 4. ScanSource — PASS

- `struct SSHSource: ScanSource` implements `enumerate`, `trash`, `reveal`, `resolveDisplayPath`, `supportsTrash`.
- Dependency-injected `clientFactory` enables `FakeSFTPClient` tests without sockets.
- Concurrency capped at 3 listings (within plan 2–4).
- Wired: `AppModel.scanSource` / `makeSSHSource` / `startSSHScan`, `saveSSHProfileAndScan`, sidebar/empty-state/accounts “Add SSH”.

### 5. No free-form shell — PASS

- Package depends on **Citadel** (NIOSSH); `CitadelSFTPBridge` opens SFTP in-process.
- No `Process` / `/usr/bin/ssh` / free-form shell for list/stat/rename/remove.
- Reveal: pasteboard `user@host:path` plus optional Terminal AppleScript that only `echo`s a message (design §5.5 “optional Open in Terminal”). Path single-quote escaped. This is not shell-driven SFTP.

---

## Plan / design coverage

| Plan item | Status |
|-----------|--------|
| `SSHProfile` + auth method + remote trash path | Done |
| Secrets not in profile struct | Done |
| TOFU host key storage | Done (Keychain) |
| SFTP readdir enumerate | Done (`FakeSFTPClient` + Citadel) |
| Low concurrency 2–4 | Done (3) |
| Trash rename / strong permanent confirm | Done |
| Reveal pasteboard + optional Terminal | Done |
| Path normalize tests first | Present (`PathNormalizationTests`) |
| UI Add SSH + test connection | Done (`SSHProfileSheet`) |
| Citadel SPM dependency | Done (`Package.swift` / resolved 0.12.1) |

---

## Non-blocking notes (do not block Approved)

1. **TOFU fingerprint material** — `CitadelSFTPBridge` uses `String(describing: NIOSSHPublicKey)`. Prefer a stable hash of the public key blob if false host-key-changed prompts appear across library updates.
2. **`makeSSHSource` cache fallback** — if `sshProfiles` is empty, a localhost placeholder is used for `SSHSource.profile` (including `remoteTrashPath`). Connection reloads profile from store, but trash-path policy uses the outer profile. Prefer always resolving profile from `SSHCredentialStore` before building the source (async API).
3. **Strong confirm is UI-enforced** — `confirmPending` sets `allowPermanentDelete` without re-checking the typed phrase; `ConfirmTrashSheet` disables the button until `DELETE`. Adequate for single UI entry point; service-layer re-check would be belt-and-suspenders.
4. **HostKeyCapture** — `@unchecked Sendable` shared mutable state across NIO callback and async connect; small race risk on first-connect fingerprint persistence (mitigated by secondary `validateOrTrustHostKey`).

---

## Test inventory (Task 13)

- `PathNormalizationTests` — normalize / join / parent / rootRef  
- `SSHSourceTests` — enumerate tree sizes, trash rename, permanent gate, confirm flag  
- `RemovalServiceTests` — SSH with/without trash path strong-confirm messaging  

---

## Verdict

**Approved**

All must-checks are satisfied: path normalize tests, trash rename or DELETE confirm, Keychain secrets, `ScanSource` integration, and no free-form shell for SFTP operations. Non-blocking notes may be follow-ups in Task 15/16 polish if desired.
