import AppKit
import Foundation
import Observation

/// One row in the outline tree (flattened with depth for disclosure UI).
struct TreeOutlineRow: Identifiable, Hashable, Sendable {
    var id: String
    var depth: Int
    var name: String
    var itemCount: Int64
    var byteSize: Int64
    var percentOfParent: Double
    var nodeKind: NodeKind
    var permissionsState: PermissionsState
    var isDirectoryLike: Bool
    var isExpanded: Bool
    var hasChildren: Bool
    var logicalPath: String
}

struct BreadcrumbItem: Identifiable, Hashable, Sendable {
    var id: String
    var title: String
}

@MainActor
@Observable
final class AppModel {
    let index = ScanIndex()
    let locationStore: LocationStore
    let removalService: RemovalService
    let diagnosticsLog = DiagnosticsLog()
    let authStore: AuthStore
    let sshCredentialStore: SSHCredentialStore
    let preferences: AppPreferences

    private(set) var store: SQLiteStore?
    private(set) var coordinator: ScanCoordinator?
    private(set) var oauthConfig: OAuthConfig

    var locations: [ScanLocation] = []
    /// Google account emails known to AuthStore (refreshed after connect / settings).
    private(set) var googleAccounts: [String] = []
    /// Microsoft / OneDrive account emails known to AuthStore.
    private(set) var microsoftAccounts: [String] = []
    /// Saved SSH profiles (metadata only; secrets in Keychain).
    private(set) var sshProfiles: [SSHProfile] = []

    // MARK: - UI state

    var selectedLocationID: UUID?
    var selectedNodeIDs: Set<String> = []
    /// When set, tree shows this folder's children as the visible roots (breadcrumb focus).
    var focusedNodeID: String?
    var searchQuery: String = ""
    var expandedNodeIDs: Set<String> = []

    private(set) var treeRows: [TreeOutlineRow] = []
    private(set) var typeTotals: [TypeTotal] = []
    private(set) var breadcrumbs: [BreadcrumbItem] = []
    private(set) var selectedNodes: [StorageNode] = []
    private(set) var statusMessage: String?
    /// Snapshot of coordinator progress for the selected location (drives ProgressHeaderView).
    private(set) var publishedProgress: ScanProgress?

    /// User-facing notices (missing OAuth config, stubs, soft errors).
    var pendingNotice: String?

    /// True when `Config/OAuth.plist` has Google client ID + redirect.
    var isGoogleOAuthConfigured: Bool {
        oauthConfig.isGoogleConfigured
    }

    /// True when `Config/OAuth.plist` has Microsoft client ID + redirect.
    var isMicrosoftOAuthConfigured: Bool {
        oauthConfig.isMicrosoftConfigured
    }

    /// Show Full Disk Access coach sheet after a sparse / highly denied scan.
    var needsFDACoach = false
    /// Last FDA re-check result (`nil` until user taps Re-check).
    private(set) var fdaRecheckPassed: Bool?

    /// Present Add SSH profile sheet.
    var isSSHProfileSheetPresented = false
    /// When set, SSH sheet opens prefilled for edit (nil = add).
    var editingSSHProfile: SSHProfile?

    /// True while a tree row drag session is active (shows trash drop bar).
    var isNodeDragActive = false

    private var snapshotTask: Task<Void, Never>?
    private var scanTasks: [UUID: Task<Void, Never>] = [:]

    // MARK: - Derived

    var selectedLocation: ScanLocation? {
        guard let selectedLocationID else { return nil }
        return locations.first { $0.id == selectedLocationID }
    }

    /// Whether the confirm-trash sheet should be visible.
    var isTrashConfirmPresented: Bool {
        get { removalService.pendingTrash != nil }
        set {
            if !newValue {
                removalService.cancelPending()
            }
        }
    }

    var isScanningSelected: Bool {
        guard let id = selectedLocationID else { return false }
        return selectedLocation?.scanState == .scanning
            || coordinator?.progress[id] != nil && selectedLocation?.scanState == .scanning
    }

    var currentProgress: ScanProgress? {
        publishedProgress
    }

    var hasScannedContent: Bool {
        !treeRows.isEmpty || selectedLocation?.scanState == .scanning
            || selectedLocation?.scanState == .complete
            || selectedLocation?.scanState == .cancelled
            || selectedLocation?.scanState == .failed
    }

    var localLocations: [ScanLocation] {
        locations.filter { $0.sourceKind == .local }
    }

    var cloudLocations: [ScanLocation] {
        locations.filter { $0.sourceKind == .googleDrive || $0.sourceKind == .oneDrive }
    }

    var sshLocations: [ScanLocation] {
        locations.filter { $0.sourceKind == .ssh }
    }

    var scanningLocations: [ScanLocation] {
        locations.filter { $0.scanState == .scanning }
    }

    // MARK: - Lifecycle

    init(
        locationStore: LocationStore = LocationStore(),
        authStore: AuthStore = AuthStore(),
        sshCredentialStore: SSHCredentialStore = SSHCredentialStore(),
        preferences: AppPreferences = AppPreferences()
    ) {
        self.locationStore = locationStore
        self.authStore = authStore
        self.sshCredentialStore = sshCredentialStore
        self.preferences = preferences
        self.oauthConfig = OAuthConfig.load()
        self.locations = (try? locationStore.load()) ?? []

        let supportDir = Self.applicationSupportDirectory()
        try? FileManager.default.createDirectory(at: supportDir, withIntermediateDirectories: true)
        let dbURL = supportDir.appendingPathComponent("index.sqlite")
        let sqlite = try? SQLiteStore(url: dbURL)
        self.store = sqlite
        // Wire store so successful trash persists remaining nodes (no resurrect on relaunch).
        self.removalService = RemovalService(index: index, store: sqlite)
        if let sqlite {
            let coord = ScanCoordinator(
                index: index,
                store: sqlite,
                maxConcurrent: preferences.scanParallelism.maxConcurrentLocations
            )
            coord.onLocationUpdate = { [weak self] updated in
                self?.applyLocationUpdate(updated)
            }
            self.coordinator = coord
        }

        if let first = locations.first {
            selectedLocationID = first.id
        }
        startSnapshotLoop()
        Task {
            await self.configureAuthRefreshers()
            await self.refreshGoogleAccounts()
            await self.refreshMicrosoftAccounts()
            await self.refreshSSHProfiles()
            await self.restorePersistedIndex()
        }
    }

    /// Apply current parallelism preference to the coordinator (call after Settings change).
    func applyScanParallelismPreference() {
        coordinator?.setMaxConcurrent(preferences.scanParallelism.maxConcurrentLocations)
    }

    /// Delete SQLite scan rows + in-memory index for all locations (locations list kept).
    func clearCachedScans() {
        Task {
            for location in locations {
                stopScan(locationId: location.id)
            }
            if let store {
                try? await store.deleteAll()
            }
            await index.removeAll()
            focusedNodeID = nil
            selectedNodeIDs = []
            expandedNodeIDs = []
            for i in locations.indices {
                locations[i].scanState = .idle
                locations[i].lastScannedAt = nil
            }
            saveLocations()
            await refreshSnapshots()
            statusMessage = "Cleared cached scan data."
            await diagnosticsLog.append("cleared cached scans")
        }
    }

    func refreshSSHProfiles() async {
        sshProfiles = (try? await sshCredentialStore.loadProfiles()) ?? []
    }

    private func configureAuthRefreshers() async {
        let googleClientID = oauthConfig.googleClientID
        await authStore.setGoogleRefresher { refreshToken in
            guard let googleClientID, !googleClientID.isEmpty else {
                throw GoogleOAuthClient.GoogleOAuthError.missingClientID
            }
            return try await GoogleOAuthClient.refresh(refreshToken: refreshToken, clientID: googleClientID)
        }

        let microsoftClientID = oauthConfig.microsoftClientID
        await authStore.setMicrosoftRefresher { refreshToken in
            guard let microsoftClientID, !microsoftClientID.isEmpty else {
                throw MicrosoftOAuthClient.MicrosoftOAuthError.missingClientID
            }
            return try await MicrosoftOAuthClient.refresh(
                refreshToken: refreshToken,
                clientID: microsoftClientID
            )
        }
    }

    func refreshGoogleAccounts() async {
        googleAccounts = (try? await authStore.listAccounts(provider: .google)) ?? []
    }

    func refreshMicrosoftAccounts() async {
        microsoftAccounts = (try? await authStore.listAccounts(provider: .microsoft)) ?? []
    }

    func reloadOAuthConfig() {
        oauthConfig = OAuthConfig.load()
    }

    // MARK: - Location persistence

    func saveLocations() {
        try? locationStore.save(locations)
    }

    func applyLocationUpdate(_ updated: ScanLocation) {
        if let idx = locations.firstIndex(where: { $0.id == updated.id }) {
            locations[idx] = updated
        } else {
            locations.append(updated)
        }
        saveLocations()
        Task { await refreshSnapshots() }
    }

    func selectLocation(_ id: UUID?) {
        selectedLocationID = id
        selectedNodeIDs = []
        focusedNodeID = nil
        expandedNodeIDs = []
        searchQuery = ""
        Task { await refreshSnapshots() }
    }

    func updateSelection(_ ids: Set<String>) {
        selectedNodeIDs = ids
        Task { await refreshSelectedNodes() }
    }

    func removeLocation(_ id: UUID) {
        stopScan(locationId: id)
        locations.removeAll { $0.id == id }
        saveLocations()
        if selectedLocationID == id {
            selectedLocationID = locations.first?.id
            focusedNodeID = nil
            selectedNodeIDs = []
            expandedNodeIDs = []
        }
        Task {
            if let store {
                try? await store.delete(locationId: id)
            }
            await index.remove(ids: Set(await index.nodes(for: id).map(\.id)))
            await refreshSnapshots()
        }
    }

    // MARK: - Scan actions

    /// Scan a default / quick-start local root (Home or custom path from preferences).
    func scanDefaultRoot(path: String) {
        let standardized = (path as NSString).standardizingPath
        let name = AppPreferences.displayName(forDefaultRoot: standardized)
        startLocalScan(path: standardized, displayName: name)
    }

    /// Scan the user's home directory (creates or reuses a local Home location).
    func scanHome() {
        scanDefaultRoot(path: NSHomeDirectory())
    }

    /// Present a folder picker and scan the chosen volume/folder.
    func scanVolume() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.message = "Choose a folder or volume to scan"
        panel.prompt = "Scan"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let path = url.standardizedFileURL.path
        let name = url.lastPathComponent.isEmpty ? path : url.lastPathComponent
        startLocalScan(path: path, displayName: name)
    }

    func addLocation() {
        scanVolume()
    }

    func rescanSelected() {
        guard let location = selectedLocation else { return }
        switch location.sourceKind {
        case .local:
            startLocalScan(path: location.rootRef, displayName: location.displayName, existing: location)
        case .googleDrive:
            startGoogleDriveScan(location: location)
        case .oneDrive:
            startOneDriveScan(location: location)
        case .ssh:
            startSSHScan(location: location)
        }
    }

    func stopSelected() {
        guard let id = selectedLocationID else { return }
        stopScan(locationId: id)
    }

    func stopScan(locationId: UUID) {
        coordinator?.cancel(locationId: locationId)
    }

    /// Sign in with Google (PKCE) when OAuth.plist is configured; add My Drive location and scan.
    ///
    /// Scope requested: Drive list + trash (`https://www.googleapis.com/auth/drive`) with offline refresh.
    func connectGoogle() {
        reloadOAuthConfig()
        guard oauthConfig.isGoogleConfigured else {
            pendingNotice =
                "Google Drive is not configured. Copy Config/OAuth.example.plist to Config/OAuth.plist, set GoogleClientID and GoogleRedirectURI, then restart. Cistilka requests Drive list + Trash access."
            return
        }

        statusMessage = "Signing in to Google…"
        Task {
            do {
                let client = GoogleOAuthClient(config: oauthConfig)
                let tokens = try await client.signIn()
                let email: String
                if let known = tokens.accountEmail, !known.isEmpty {
                    email = known
                } else if let fetched = try? await client.fetchUserEmail(accessToken: tokens.accessToken) {
                    email = fetched
                } else {
                    email = "Google account"
                }
                var stored = tokens
                stored.accountEmail = email
                stored.provider = .google
                try await authStore.save(tokens: stored, accountId: email)
                await refreshGoogleAccounts()
                await diagnosticsLog.append("Google sign-in ok account=\(email)")

                let location: ScanLocation
                if let existing = locations.first(where: {
                    $0.sourceKind == .googleDrive && $0.accountId == email
                }) {
                    location = existing
                } else {
                    let created = ScanLocation(
                        id: UUID(),
                        sourceKind: .googleDrive,
                        displayName: "Google Drive (\(email))",
                        rootRef: "root",
                        accountId: email,
                        lastScannedAt: nil,
                        scanState: .idle
                    )
                    locations.append(created)
                    saveLocations()
                    location = created
                }

                selectedLocationID = location.id
                statusMessage = "Connected \(email). Scanning My Drive…"
                startGoogleDriveScan(location: location)
            } catch {
                await diagnosticsLog.append("Google sign-in failed: \(error.localizedDescription)")
                pendingNotice = "Google sign-in failed: \(error.localizedDescription)"
                statusMessage = nil
            }
        }
    }

    func signOutGoogle(accountId: String) {
        Task {
            try? await authStore.delete(accountId: accountId, provider: .google)
            await refreshGoogleAccounts()
            let toRemove = locations.filter {
                $0.sourceKind == .googleDrive && $0.accountId == accountId
            }
            for loc in toRemove {
                removeLocation(loc.id)
            }
            statusMessage = "Signed out \(accountId)."
        }
    }

    /// Sign in with Microsoft (PKCE) when OAuth.plist is configured; add OneDrive location and scan.
    ///
    /// Scopes: `offline_access User.Read Files.ReadWrite` (list + recycle-bin trash).
    func connectOneDrive() {
        reloadOAuthConfig()
        guard oauthConfig.isMicrosoftConfigured else {
            pendingNotice =
                "OneDrive is not configured. Copy Config/OAuth.example.plist to Config/OAuth.plist, set MicrosoftClientID and MicrosoftRedirectURI, then restart. Cistilka requests Files.ReadWrite (list + Recycle Bin) with offline refresh."
            return
        }

        statusMessage = "Signing in to Microsoft…"
        Task {
            do {
                let client = MicrosoftOAuthClient(config: oauthConfig)
                let tokens = try await client.signIn()
                let email: String
                if let known = tokens.accountEmail, !known.isEmpty {
                    email = known
                } else if let fetched = try? await client.fetchUserEmail(accessToken: tokens.accessToken) {
                    email = fetched
                } else {
                    email = "Microsoft account"
                }
                var stored = tokens
                stored.accountEmail = email
                stored.provider = .microsoft
                try await authStore.save(tokens: stored, accountId: email)
                await refreshMicrosoftAccounts()
                await diagnosticsLog.append("Microsoft sign-in ok account=\(email)")

                let location: ScanLocation
                if let existing = locations.first(where: {
                    $0.sourceKind == .oneDrive && $0.accountId == email
                }) {
                    location = existing
                } else {
                    let created = ScanLocation(
                        id: UUID(),
                        sourceKind: .oneDrive,
                        displayName: "OneDrive (\(email))",
                        rootRef: "root",
                        accountId: email,
                        lastScannedAt: nil,
                        scanState: .idle
                    )
                    locations.append(created)
                    saveLocations()
                    location = created
                }

                selectedLocationID = location.id
                statusMessage = "Connected \(email). Scanning OneDrive…"
                startOneDriveScan(location: location)
            } catch {
                await diagnosticsLog.append("Microsoft sign-in failed: \(error.localizedDescription)")
                pendingNotice = "Microsoft sign-in failed: \(error.localizedDescription)"
                statusMessage = nil
            }
        }
    }

    func signOutMicrosoft(accountId: String) {
        Task {
            try? await authStore.delete(accountId: accountId, provider: .microsoft)
            await refreshMicrosoftAccounts()
            let toRemove = locations.filter {
                $0.sourceKind == .oneDrive && $0.accountId == accountId
            }
            for loc in toRemove {
                removeLocation(loc.id)
            }
            statusMessage = "Signed out \(accountId)."
        }
    }

    func addSSH() {
        editingSSHProfile = nil
        isSSHProfileSheetPresented = true
    }

    func editSSH(_ profile: SSHProfile) {
        editingSSHProfile = profile
        isSSHProfileSheetPresented = true
    }

    func dismissSSHProfileSheet() {
        isSSHProfileSheetPresented = false
        editingSSHProfile = nil
    }

    /// Live SFTP probe (Citadel) using temporary TOFU for this host.
    func testSSHConnection(profile: SSHProfile, secrets: SSHSecrets) async throws {
        let client = try await CitadelSFTPBridge.connect(
            profile: profile,
            secrets: secrets,
            hostKeyStore: sshCredentialStore
        )
        defer { Task { try? await client.close() } }
        _ = try await client.listDirectory(at: RemotePath.normalize(profile.remotePath))
        await diagnosticsLog.append("SSH test ok \(profile.username)@\(profile.host):\(profile.port)")
    }

    /// Persist profile + secrets, add location, start scan.
    func saveSSHProfileAndScan(profile: SSHProfile, secrets: SSHSecrets) async throws {
        // Verify credentials before saving permanently.
        let client = try await CitadelSFTPBridge.connect(
            profile: profile,
            secrets: secrets,
            hostKeyStore: sshCredentialStore
        )
        try? await client.close()

        try await sshCredentialStore.upsert(profile)
        try await sshCredentialStore.saveSecrets(secrets, profileId: profile.id)
        await refreshSSHProfiles()

        let location: ScanLocation
        if let existing = locations.first(where: {
            $0.sourceKind == .ssh && $0.accountId == profile.id.uuidString
        }) {
            var updated = existing
            updated.displayName = profile.displayName
            updated.rootRef = profile.rootRef
            applyLocationUpdate(updated)
            location = updated
        } else {
            let created = ScanLocation(
                id: UUID(),
                sourceKind: .ssh,
                displayName: profile.displayName,
                rootRef: profile.rootRef,
                accountId: profile.id.uuidString,
                lastScannedAt: nil,
                scanState: .idle
            )
            locations.append(created)
            saveLocations()
            location = created
        }

        selectedLocationID = location.id
        statusMessage = "Scanning \(location.displayName)…"
        startSSHScan(location: location, profile: profile)
    }

    func deleteSSHProfile(_ profile: SSHProfile) {
        Task {
            try? await sshCredentialStore.deleteProfile(id: profile.id)
            try? await sshCredentialStore.clearHostKey(host: profile.host, port: profile.port)
            await refreshSSHProfiles()
            let toRemove = locations.filter {
                $0.sourceKind == .ssh && $0.accountId == profile.id.uuidString
            }
            for loc in toRemove {
                removeLocation(loc.id)
            }
            statusMessage = "Removed SSH profile \(profile.displayName)."
        }
    }

    func clearPendingNotice() {
        pendingNotice = nil
    }

    // MARK: - Full Disk Access coach

    func dismissFDACoach() {
        needsFDACoach = false
        fdaRecheckPassed = nil
    }

    func presentFDACoach() {
        needsFDACoach = true
    }

    @MainActor
    func openFullDiskAccessSettings() {
        let opened = PermissionCoach.openFullDiskAccessSettings()
        if !opened {
            PermissionCoach.copyFullDiskAccessInstructions()
            statusMessage = "Could not open Settings; FDA steps copied to clipboard."
        }
        Task {
            await diagnosticsLog.append(opened ? "Opened Full Disk Access settings" : "FDA settings URL failed; copied instructions")
        }
    }

    func recheckFullDiskAccess() {
        let ok = PermissionCoach.hasLikelyFullDiskAccess()
        fdaRecheckPassed = ok
        statusMessage = ok
            ? "Full Disk Access looks available. Rescan for complete results."
            : "Still missing Full Disk Access for protected folders."
        Task {
            await diagnosticsLog.append(ok ? "FDA re-check: passed" : "FDA re-check: blocked")
        }
    }

    func exportDiagnostics() {
        Task {
            do {
                let url = try await diagnosticsLog.exportToTemporaryFile()
                NSWorkspace.shared.activateFileViewerSelecting([url])
                statusMessage = "Diagnostics exported."
            } catch {
                statusMessage = "Diagnostics export failed: \(error.localizedDescription)"
            }
        }
    }

    /// Evaluate scan results and set `needsFDACoach` when denials/home size look wrong.
    func evaluatePermissionCoach(for location: ScanLocation) async {
        guard location.sourceKind == .local else { return }
        let nodes = await index.nodes(for: location.id)
        let denied = nodes.filter { $0.permissionsState == .denied }.count
        let totalBytes = nodes.filter { $0.parentId == nil }.map(\.byteSize).max()
            ?? nodes.map(\.byteSize).max()
            ?? 0
        let isHome = PermissionCoach.isHomeRootPath(location.rootRef)
        let needs = PermissionCoach.needsFDACoach(
            deniedNodeCount: denied,
            totalScannedBytes: totalBytes,
            isHomeScan: isHome
        )
        await diagnosticsLog.append(
            "scan complete location=\(location.displayName) denied=\(denied) bytes=\(totalBytes) home=\(isHome) coach=\(needs)"
        )
        if needs {
            needsFDACoach = true
            fdaRecheckPassed = nil
        }
    }

    // MARK: - Navigation / focus

    func focusNode(id: String?) {
        focusedNodeID = id
        selectedNodeIDs = []
        expandedNodeIDs = []
        Task { await refreshSnapshots() }
    }

    func toggleExpanded(id: String) {
        if expandedNodeIDs.contains(id) {
            expandedNodeIDs.remove(id)
            // Collapse descendants
            expandedNodeIDs = expandedNodeIDs.filter { !$0.hasPrefix(id + "/") && $0 != id }
        } else {
            expandedNodeIDs.insert(id)
        }
        Task { await refreshSnapshots() }
    }

    func selectSingleNode(id: String) {
        selectedNodeIDs = [id]
        Task { await refreshSelectedNodes() }
    }

    // MARK: - Reveal / Trash

    /// Active `ScanSource` for the selected location.
    func scanSource(for location: ScanLocation) -> (any ScanSource)? {
        switch location.sourceKind {
        case .local:
            return preferences.makeLocalDiskSource()
        case .googleDrive:
            guard let accountId = location.accountId else { return nil }
            let authStore = self.authStore
            return GoogleDriveSource(
                accessTokenProvider: { forceRefresh in
                    try await authStore.validAccessToken(
                        accountId: accountId,
                        provider: .google,
                        forceRefresh: forceRefresh
                    )
                },
                cloudStorageRoot: Self.preferredGoogleCloudStorageRoot()
            )
        case .oneDrive:
            guard let accountId = location.accountId else { return nil }
            let authStore = self.authStore
            return OneDriveSource(
                accessTokenProvider: { forceRefresh in
                    try await authStore.validAccessToken(
                        accountId: accountId,
                        provider: .microsoft,
                        forceRefresh: forceRefresh
                    )
                },
                cloudStorageRoot: Self.preferredOneDriveCloudStorageRoot()
            )
        case .ssh:
            return makeSSHSource(for: location, allowPermanentDelete: false)
        }
    }

    /// Build `SSHSource` for a location (loads profile + secrets from store).
    func makeSSHSource(for location: ScanLocation, allowPermanentDelete: Bool) -> SSHSource? {
        guard let accountId = location.accountId,
              let profileId = UUID(uuidString: accountId)
        else {
            return nil
        }
        // Profile metadata is loaded sync from cache when possible.
        let profile: SSHProfile
        if let cached = sshProfiles.first(where: { $0.id == profileId }) {
            profile = cached
        } else {
            // Fallback placeholder from rootRef (scan will still need secrets).
            profile = SSHProfile(
                id: profileId,
                displayName: location.displayName,
                host: "localhost",
                port: 22,
                username: "user",
                remotePath: location.rootRef
            )
        }
        let store = sshCredentialStore
        return SSHSource(
            profile: profile,
            allowPermanentDelete: allowPermanentDelete,
            clientFactory: {
                let resolved = try await store.profile(id: profileId) ?? profile
                let secrets = try await store.requireSecrets(profileId: profileId)
                return try await CitadelSFTPBridge.connect(
                    profile: resolved,
                    secrets: secrets,
                    hostKeyStore: store
                )
            }
        )
    }

    func revealNode(_ node: StorageNode) {
        guard let location = selectedLocation, let source = scanSource(for: location) else {
            pendingNotice = "Reveal is not available for this source yet."
            return
        }
        Task {
            do {
                try await RevealService.reveal(node: node, source: source)
            } catch {
                statusMessage = "Reveal failed: \(error.localizedDescription)"
            }
        }
    }

    func revealSelected() {
        guard let node = selectedNodes.first else { return }
        revealNode(node)
    }

    /// Selected nodes that are eligible for Trash (not permission-denied).
    var trashableSelectedNodes: [StorageNode] {
        RemovalService.trashableNodes(from: selectedNodes)
    }

    /// Whether the current selection can be sent to Trash (source supports it + ≥1 trashable node).
    var canTrashCurrentSelection: Bool {
        guard !trashableSelectedNodes.isEmpty else { return false }
        guard let location = selectedLocation else { return false }
        guard let source = scanSource(for: location) else { return false }
        return source.supportsTrash
    }

    /// Node IDs to put on the drag pasteboard for a row (full multi-select when row is selected).
    func dragPayloadIDs(for rowID: String) -> [String] {
        if selectedNodeIDs.contains(rowID), selectedNodeIDs.count > 1 {
            return Array(selectedNodeIDs)
        }
        return [rowID]
    }

    /// Stage trash for the current multi-selection (confirm sheet).
    /// Resolves via `selectedNodeIDs` + index (not async-lagged `selectedNodes`).
    func requestTrashForSelection() {
        requestTrash(nodeIDs: selectedNodeIDs)
    }

    /// Stage trash for explicit nodes (context menu on a single row).
    func requestTrash(nodes: [StorageNode]) {
        guard !nodes.isEmpty else { return }
        let eligible = RemovalService.trashableNodes(from: nodes)
        guard !eligible.isEmpty else {
            pendingNotice = "Selected items cannot be moved to Trash (permission denied)."
            return
        }
        // Group by location so mixed multi-select confirms per source kind.
        Task {
            await requestTrashResolvingSources(nodes: eligible)
        }
    }

    /// Resolve node IDs from the live index, then stage trash (preferred over stale `selectedNodes`).
    func requestTrash(nodeIDs: Set<String>) {
        guard !nodeIDs.isEmpty else { return }
        Task {
            var nodes: [StorageNode] = []
            for id in nodeIDs {
                if let n = await index.node(id: id) {
                    nodes.append(n)
                }
            }
            guard !nodes.isEmpty else {
                pendingNotice = "Selected items are no longer in the index."
                return
            }
            requestTrash(nodes: nodes)
        }
    }

    /// Drop on trash bar: same pipeline as menu / ⌘⌫ (filters denied, groups mixed sources).
    @discardableResult
    func handleTrashDrop(nodeIDs: [String]) -> Bool {
        let unique = Array(Set(nodeIDs))
        guard !unique.isEmpty else { return false }
        isNodeDragActive = false
        // Same ID → index resolution path as selection trash.
        requestTrash(nodeIDs: Set(unique))
        return true
    }

    /// Context menu / keyboard: if `rowID` is in the selection, trash the whole selection; else that row.
    func requestTrashFromContext(rowID: String) {
        if selectedNodeIDs.contains(rowID) {
            requestTrash(nodeIDs: selectedNodeIDs)
        } else {
            requestTrash(nodeIDs: [rowID])
        }
    }

    func cancelTrashConfirm() {
        removalService.cancelPending()
    }

    func confirmTrash() {
        Task {
            let results = await removalService.confirmPending()
            var successCount = 0
            var failCount = 0
            var removedIDs = Set<String>()
            for result in results {
                switch result {
                case .movedToTrash(let id):
                    successCount += 1
                    removedIDs.insert(id)
                case .failed:
                    failCount += 1
                }
            }
            selectedNodeIDs.subtract(removedIDs)
            if focusedNodeID.map({ removedIDs.contains($0) }) == true {
                focusedNodeID = nil
            }
            expandedNodeIDs.subtract(removedIDs)
            await refreshSnapshots()
            if failCount == 0, successCount > 0 {
                statusMessage = "Moved \(successCount) item\(successCount == 1 ? "" : "s") to Trash."
            } else if successCount > 0 {
                statusMessage = "Moved \(successCount) to Trash; \(failCount) failed."
            } else if failCount > 0 {
                statusMessage = "Could not move \(failCount) item\(failCount == 1 ? "" : "s") to Trash."
            }
            // Mixed sources: another confirm sheet may still be pending.
        }
    }

    /// Resolve each node's location → ScanSource, group, then stage confirms.
    private func requestTrashResolvingSources(nodes: [StorageNode]) async {
        var byLocation: [UUID: [StorageNode]] = [:]
        for node in nodes {
            byLocation[node.locationId, default: []].append(node)
        }

        var groups: [(nodes: [StorageNode], source: any ScanSource)] = []
        var skippedUnsupported = 0
        for (locationId, groupNodes) in byLocation {
            guard let location = locations.first(where: { $0.id == locationId }) else {
                skippedUnsupported += groupNodes.count
                continue
            }
            guard let source = scanSource(for: location) else {
                skippedUnsupported += groupNodes.count
                continue
            }
            guard source.supportsTrash else {
                skippedUnsupported += groupNodes.count
                continue
            }
            groups.append((groupNodes, source))
        }

        guard !groups.isEmpty else {
            pendingNotice = skippedUnsupported > 0
                ? "This source does not support Trash."
                : "Trash is not available for the selected items."
            return
        }

        if groups.count == 1 {
            removalService.requestTrash(nodes: groups[0].nodes, source: groups[0].source)
        } else {
            removalService.requestTrashGrouped(groups: groups)
        }
    }

    // MARK: - Snapshot loop (≤ ~15 Hz)

    private func startSnapshotLoop() {
        snapshotTask?.cancel()
        snapshotTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.refreshSnapshots()
                let scanning = self.locations.contains { $0.scanState == .scanning }
                let nanos: UInt64 = scanning ? 66_000_000 : 500_000_000
                try? await Task.sleep(nanoseconds: nanos)
            }
        }
    }

    func refreshSnapshots() async {
        if let id = selectedLocationID {
            publishedProgress = coordinator?.progress[id]
        } else {
            publishedProgress = nil
        }
        await rebuildBreadcrumbs()
        await rebuildTreeRows()
        await rebuildTypeTotals()
        await refreshSelectedNodes()
    }

    private func rebuildBreadcrumbs() async {
        guard let location = selectedLocation else {
            breadcrumbs = []
            return
        }
        var items: [BreadcrumbItem] = [
            BreadcrumbItem(id: "location:\(location.id.uuidString)", title: location.displayName),
        ]
        guard let focusedNodeID else {
            breadcrumbs = items
            return
        }
        // Walk up from focused node to root.
        var chain: [StorageNode] = []
        var currentID: String? = focusedNodeID
        while let id = currentID, let node = await index.node(id: id) {
            chain.append(node)
            currentID = node.parentId
        }
        for node in chain.reversed() {
            items.append(BreadcrumbItem(id: node.id, title: node.name))
        }
        breadcrumbs = items
    }

    private func rebuildTreeRows() async {
        guard let locationID = selectedLocationID else {
            treeRows = []
            return
        }

        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        if !query.isEmpty {
            treeRows = await searchRows(locationID: locationID, query: query)
            return
        }

        let parentID = focusedNodeID
        let roots = await childrenForLocation(locationID: locationID, parentID: parentID)
        var rows: [TreeOutlineRow] = []
        for root in roots {
            await appendOutline(
                node: root,
                parentSize: parentSizeForPercent(parentID: parentID, fallback: root),
                depth: 0,
                into: &rows
            )
        }
        treeRows = rows
    }

    private func parentSizeForPercent(parentID: String?, fallback: StorageNode) async -> Int64 {
        if let parentID, let parent = await index.node(id: parentID) {
            return parent.byteSize
        }
        // Forest roots: percent of self (100%) when no parent in focus.
        return fallback.byteSize
    }

    private func appendOutline(
        node: StorageNode,
        parentSize: Int64,
        depth: Int,
        into rows: inout [TreeOutlineRow]
    ) async {
        let isDir = node.nodeKind == .folder
        let kids = isDir ? await index.children(of: node.id) : []
        let expanded = expandedNodeIDs.contains(node.id)
        let percent: Double
        if depth == 0, focusedNodeID == nil, node.parentId == nil {
            percent = 1
        } else {
            percent = node.percentOfParent(parentSize: parentSize)
        }
        rows.append(
            TreeOutlineRow(
                id: node.id,
                depth: depth,
                name: node.name,
                itemCount: node.itemCount,
                byteSize: node.byteSize,
                percentOfParent: percent,
                nodeKind: node.nodeKind,
                permissionsState: node.permissionsState,
                isDirectoryLike: isDir,
                isExpanded: expanded,
                hasChildren: isDir && (!kids.isEmpty || node.itemCount > 0),
                logicalPath: node.logicalPath
            )
        )
        if isDir, expanded {
            for child in kids {
                await appendOutline(
                    node: child,
                    parentSize: node.byteSize,
                    depth: depth + 1,
                    into: &rows
                )
            }
        }
    }

    private func searchRows(locationID: UUID, query: String) async -> [TreeOutlineRow] {
        let all = await index.nodes(for: locationID)
        let scopePrefix: String?
        if let focusedNodeID, let focused = all.first(where: { $0.id == focusedNodeID }) {
            scopePrefix = focused.logicalPath
        } else {
            scopePrefix = nil
        }

        let filtered = all.filter { node in
            if let scopePrefix {
                let path = node.logicalPath
                guard path == scopePrefix || path.hasPrefix(scopePrefix + "/") else { return false }
            }
            return node.name.localizedCaseInsensitiveContains(query)
        }
        .sorted { a, b in
            if a.byteSize != b.byteSize { return a.byteSize > b.byteSize }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }

        return filtered.map { node in
            TreeOutlineRow(
                id: node.id,
                depth: 0,
                name: node.name,
                itemCount: node.itemCount,
                byteSize: node.byteSize,
                percentOfParent: 0,
                nodeKind: node.nodeKind,
                permissionsState: node.permissionsState,
                isDirectoryLike: node.nodeKind == .folder,
                isExpanded: false,
                hasChildren: false,
                logicalPath: node.logicalPath
            )
        }
    }

    private func childrenForLocation(locationID: UUID, parentID: String?) async -> [StorageNode] {
        let kids = await index.children(of: parentID)
        return kids.filter { $0.locationId == locationID }
    }

    private func rebuildTypeTotals() async {
        let scope = focusedNodeID
        // When a single folder is selected, prefer that as type-total scope.
        let selectionScope: String?
        if selectedNodeIDs.count == 1, let only = selectedNodeIDs.first {
            if let node = await index.node(id: only), node.nodeKind == .folder {
                selectionScope = only
            } else {
                selectionScope = scope
            }
        } else {
            selectionScope = scope
        }

        if selectedLocationID == nil {
            typeTotals = []
            return
        }

        // Scope nil means entire index; filter by walking location roots when unfocused.
        if let selectionScope {
            typeTotals = await index.typeTotals(scopeRootId: selectionScope)
        } else if let focusedNodeID {
            typeTotals = await index.typeTotals(scopeRootId: focusedNodeID)
        } else if let locationID = selectedLocationID {
            let roots = await childrenForLocation(locationID: locationID, parentID: nil)
            if roots.count == 1 {
                typeTotals = await index.typeTotals(scopeRootId: roots[0].id)
            } else {
                // Aggregate per-root totals for multi-root (rare).
                var merged: [String: (count: Int, bytes: Int64)] = [:]
                for root in roots {
                    let totals = await index.typeTotals(scopeRootId: root.id)
                    for t in totals {
                        var bucket = merged[t.fileExtension] ?? (0, 0)
                        bucket.count += t.count
                        bucket.bytes += t.bytes
                        merged[t.fileExtension] = bucket
                    }
                }
                typeTotals = merged
                    .map { TypeTotal(fileExtension: $0.key, count: $0.value.count, bytes: $0.value.bytes) }
                    .sorted { a, b in
                        if a.bytes != b.bytes { return a.bytes > b.bytes }
                        return a.fileExtension.localizedStandardCompare(b.fileExtension) == .orderedAscending
                    }
            }
        } else {
            typeTotals = []
        }
    }

    private func refreshSelectedNodes() async {
        var nodes: [StorageNode] = []
        for id in selectedNodeIDs {
            if let n = await index.node(id: id) {
                nodes.append(n)
            }
        }
        selectedNodes = nodes
    }

    // MARK: - Google Drive scan wiring

    private func startGoogleDriveScan(location: ScanLocation) {
        guard let coordinator else {
            statusMessage = "Scan store unavailable."
            return
        }
        guard let accountId = location.accountId else {
            pendingNotice = "Google Drive location is missing an account. Connect Google again."
            return
        }

        selectedLocationID = location.id
        focusedNodeID = nil
        expandedNodeIDs = []
        selectedNodeIDs = []
        searchQuery = ""
        statusMessage = "Scanning \(location.displayName)…"

        let authStore = self.authStore
        let locationID = location.id
        scanTasks[locationID]?.cancel()
        scanTasks[locationID] = Task { [weak self] in
            guard let self else { return }
            let source = GoogleDriveSource(
                accessTokenProvider: { forceRefresh in
                    try await authStore.validAccessToken(
                        accountId: accountId,
                        provider: .google,
                        forceRefresh: forceRefresh
                    )
                },
                cloudStorageRoot: Self.preferredGoogleCloudStorageRoot()
            )
            await diagnosticsLog.append("scan start Google Drive account=\(accountId)")
            await coordinator.startScan(location: location, source: source, mode: .full)
            await self.refreshSnapshots()
            if self.selectedLocation?.scanState == .complete {
                self.statusMessage = "Scan complete."
            } else if self.selectedLocation?.scanState == .cancelled {
                self.statusMessage = "Scan stopped (partial results kept)."
            } else if self.selectedLocation?.scanState == .failed {
                self.statusMessage = "Google Drive scan failed."
                await diagnosticsLog.append("scan failed Google Drive account=\(accountId)")
            }
            self.scanTasks[locationID] = nil
        }
    }

    /// Best-effort Google Drive for Desktop mirror under CloudStorage.
    private static func preferredGoogleCloudStorageRoot() -> URL? {
        cloudStorageFolder(matching: { name in
            name.hasPrefix("GoogleDrive") || name.hasPrefix("GoogleDrive-")
        })
    }

    // MARK: - OneDrive scan wiring

    private func startOneDriveScan(location: ScanLocation) {
        guard let coordinator else {
            statusMessage = "Scan store unavailable."
            return
        }
        guard let accountId = location.accountId else {
            pendingNotice = "OneDrive location is missing an account. Connect OneDrive again."
            return
        }

        selectedLocationID = location.id
        focusedNodeID = nil
        expandedNodeIDs = []
        selectedNodeIDs = []
        searchQuery = ""
        statusMessage = "Scanning \(location.displayName)…"

        let authStore = self.authStore
        let locationID = location.id
        scanTasks[locationID]?.cancel()
        scanTasks[locationID] = Task { [weak self] in
            guard let self else { return }
            let source = OneDriveSource(
                accessTokenProvider: { forceRefresh in
                    try await authStore.validAccessToken(
                        accountId: accountId,
                        provider: .microsoft,
                        forceRefresh: forceRefresh
                    )
                },
                cloudStorageRoot: Self.preferredOneDriveCloudStorageRoot()
            )
            await diagnosticsLog.append("scan start OneDrive account=\(accountId)")
            await coordinator.startScan(location: location, source: source, mode: .full)
            await self.refreshSnapshots()
            if self.selectedLocation?.scanState == .complete {
                self.statusMessage = "Scan complete."
            } else if self.selectedLocation?.scanState == .cancelled {
                self.statusMessage = "Scan stopped (partial results kept)."
            } else if self.selectedLocation?.scanState == .failed {
                self.statusMessage = "OneDrive scan failed."
                await diagnosticsLog.append("scan failed OneDrive account=\(accountId)")
            }
            self.scanTasks[locationID] = nil
        }
    }

    /// Best-effort OneDrive for Desktop mirror under CloudStorage.
    private static func preferredOneDriveCloudStorageRoot() -> URL? {
        cloudStorageFolder(matching: { name in
            name.hasPrefix("OneDrive")
        })
    }

    private static func cloudStorageFolder(matching predicate: (String) -> Bool) -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let cloud = home
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("CloudStorage", isDirectory: true)
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: cloud,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }
        return contents.first { predicate($0.lastPathComponent) }
    }

    // MARK: - SSH scan wiring

    private func startSSHScan(location: ScanLocation, profile: SSHProfile? = nil) {
        guard let coordinator else {
            statusMessage = "Scan store unavailable."
            return
        }
        guard let accountId = location.accountId, let profileId = UUID(uuidString: accountId) else {
            pendingNotice = "SSH location is missing a profile. Add SSH again."
            return
        }

        selectedLocationID = location.id
        focusedNodeID = nil
        expandedNodeIDs = []
        selectedNodeIDs = []
        searchQuery = ""
        statusMessage = "Scanning \(location.displayName)…"

        let store = sshCredentialStore
        let locationID = location.id
        let fallbackProfile = profile
        scanTasks[locationID]?.cancel()
        scanTasks[locationID] = Task { [weak self] in
            guard let self else { return }
            do {
                let resolved = try await store.profile(id: profileId)
                    ?? fallbackProfile
                    ?? SSHProfile(
                        id: profileId,
                        displayName: location.displayName,
                        host: "localhost",
                        username: "user",
                        remotePath: "/"
                    )
                let secrets = try await store.requireSecrets(profileId: profileId)
                let source = SSHSource(
                    profile: resolved,
                    allowPermanentDelete: false,
                    clientFactory: {
                        try await CitadelSFTPBridge.connect(
                            profile: resolved,
                            secrets: secrets,
                            hostKeyStore: store
                        )
                    }
                )
                await diagnosticsLog.append(
                    "scan start SSH \(resolved.username)@\(resolved.host):\(resolved.remotePath)"
                )
                await coordinator.startScan(location: location, source: source, mode: .full)
            } catch {
                await diagnosticsLog.append("SSH scan setup failed: \(error.localizedDescription)")
                self.pendingNotice = "SSH scan failed: \(error.localizedDescription)"
                self.statusMessage = "SSH scan failed."
                self.scanTasks[locationID] = nil
                return
            }
            await self.refreshSnapshots()
            if self.selectedLocation?.scanState == .complete {
                self.statusMessage = "Scan complete."
            } else if self.selectedLocation?.scanState == .cancelled {
                self.statusMessage = "Scan stopped (partial results kept)."
            } else if self.selectedLocation?.scanState == .failed {
                self.statusMessage = "SSH scan failed."
                await diagnosticsLog.append("scan failed SSH location=\(location.displayName)")
            }
            self.scanTasks[locationID] = nil
        }
    }

    // MARK: - Local scan wiring

    private func startLocalScan(path: String, displayName: String, existing: ScanLocation? = nil) {
        guard let coordinator else {
            statusMessage = "Scan store unavailable."
            return
        }

        let location: ScanLocation
        if let existing {
            location = existing
        } else if let found = locations.first(where: {
            $0.sourceKind == .local && $0.rootRef == path
        }) {
            location = found
        } else {
            location = ScanLocation(
                id: UUID(),
                sourceKind: .local,
                displayName: displayName,
                rootRef: path,
                accountId: nil,
                lastScannedAt: nil,
                scanState: .idle
            )
            locations.append(location)
            saveLocations()
        }

        selectedLocationID = location.id
        focusedNodeID = nil
        expandedNodeIDs = []
        selectedNodeIDs = []
        searchQuery = ""
        statusMessage = "Scanning \(location.displayName)…"

        let locationID = location.id
        let source = preferences.makeLocalDiskSource()
        applyScanParallelismPreference()
        scanTasks[locationID]?.cancel()
        scanTasks[locationID] = Task { [weak self] in
            guard let self else { return }
            await diagnosticsLog.append("scan start \(location.displayName) path=\(location.rootRef)")
            await coordinator.startScan(location: location, source: source, mode: .full)
            await self.refreshSnapshots()
            if self.selectedLocation?.scanState == .complete {
                self.statusMessage = "Scan complete."
                if let loc = self.locations.first(where: { $0.id == locationID }) {
                    await self.evaluatePermissionCoach(for: loc)
                }
            } else if self.selectedLocation?.scanState == .cancelled {
                self.statusMessage = "Scan stopped (partial results kept)."
                if let loc = self.locations.first(where: { $0.id == locationID }) {
                    await self.evaluatePermissionCoach(for: loc)
                }
            } else if self.selectedLocation?.scanState == .failed {
                let hint = self.coordinator?.progress[locationID]?.currentPath
                if let hint, hint.hasPrefix("error:") {
                    self.statusMessage = "Scan failed: \(hint.dropFirst("error:".count).trimmingCharacters(in: .whitespaces))"
                } else {
                    self.statusMessage = "Scan failed."
                }
                await diagnosticsLog.append(
                    "scan failed \(location.displayName) \(hint ?? "")"
                )
            }
            self.scanTasks[locationID] = nil
        }
    }

    private func restorePersistedIndex() async {
        guard let store else { return }
        for location in locations {
            guard let nodes = try? await store.load(locationId: location.id), !nodes.isEmpty else {
                continue
            }
            let generation = nodes.map(\.scanGeneration).max() ?? 1
            await index.apply(batch: nodes, generation: generation)
        }
        await refreshSnapshots()
    }

    private static func applicationSupportDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent(AppIdentity.bundleID, isDirectory: true)
    }
}

// MARK: - Name filter helper (testable)

enum TreeNameFilter {
    /// Returns nodes whose names contain `query` (case-insensitive). Empty query → all.
    static func filter(nodes: [StorageNode], query: String) -> [StorageNode] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return nodes }
        return nodes.filter { $0.name.localizedCaseInsensitiveContains(q) }
    }
}
