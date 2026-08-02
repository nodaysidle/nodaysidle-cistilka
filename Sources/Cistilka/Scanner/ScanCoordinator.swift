import Foundation

/// Runs location scans off the main path, coalesces batches into `ScanIndex`, and persists on completion.
@MainActor
final class ScanCoordinator {
    private let index: ScanIndex
    private let store: SQLiteStore
    /// Max concurrent location scans (updated from scan-parallelism preference).
    private(set) var maxConcurrent: Int

    private(set) var progress: [UUID: ScanProgress] = [:]

    /// Invoked when a location's scan lifecycle fields change (state, lastScannedAt).
    var onLocationUpdate: ((ScanLocation) -> Void)?

    /// Highest generation number assigned for a location (in-flight or last assigned).
    private var generations: [UUID: UInt64] = [:]
    /// Last successfully completed full-scan generation (stable tree to keep on cancel).
    private var committedGenerations: [UUID: UInt64] = [:]
    private var activeTasks: [UUID: Task<ScanOutcome, Never>] = [:]
    /// Monotonic per-location token; only the owning `startScan` call may clear tasks / apply final state.
    private var startTokens: [UUID: UInt64] = [:]
    private var nextStartToken: UInt64 = 1
    private var activeScanCount = 0
    private var slotWaiters: [CheckedContinuation<Void, Never>] = []

    init(index: ScanIndex, store: SQLiteStore, maxConcurrent: Int = 2) {
        self.index = index
        self.store = store
        self.maxConcurrent = max(1, maxConcurrent)
    }

    /// Apply parallelism preference (max concurrent full-location scans).
    func setMaxConcurrent(_ value: Int) {
        maxConcurrent = max(1, value)
        // Wake waiters if capacity increased.
        while activeScanCount < maxConcurrent, !slotWaiters.isEmpty {
            let cont = slotWaiters.removeFirst()
            cont.resume()
        }
    }

    /// Starts (or restarts) a scan for `location`. Awaits completion or cancellation.
    func startScan(location: ScanLocation, source: any ScanSource, mode: ScanMode) async {
        // Claim ownership of this start; supersedes any concurrent startScan for the same location.
        let token = nextStartToken
        nextStartToken &+= 1
        startTokens[location.id] = token

        // One active full scan per location: cancel any in-flight work first.
        if let existing = activeTasks[location.id] {
            existing.cancel()
            _ = await existing.value
        }

        // Another startScan may have taken ownership while we awaited the cancel.
        guard startTokens[location.id] == token else { return }

        await acquireSlot()
        defer { releaseSlot() }

        // Re-check after acquiring a slot (another caller may have superseded us while we waited).
        guard startTokens[location.id] == token else { return }

        var working = location
        working.scanState = .scanning
        onLocationUpdate?(working)

        /// Committed tree generation to keep if this full scan cancels/fails (nil = first scan).
        let committedGeneration: UInt64?
        let generation: UInt64
        switch mode {
        case .full:
            committedGeneration = committedGenerations[location.id]
            let next = (generations[location.id] ?? committedGeneration ?? 0) + 1
            generations[location.id] = next
            generation = next
        case .refreshSubtree:
            // Subtree refresh reuses the current generation when present; otherwise starts at 1.
            committedGeneration = nil
            let next = generations[location.id] ?? committedGenerations[location.id] ?? 1
            generations[location.id] = next
            generation = next
        }

        progress[location.id] = ScanProgress()

        let index = self.index
        let store = self.store
        let locationId = location.id
        let locationSnapshot = working
        let isFull = {
            if case .full = mode { return true }
            return false
        }()

        let setProgress: @MainActor @Sendable (ScanProgress) -> Void = { [weak self] p in
            self?.progress[locationId] = p
        }
        /// Publish completed gen before the detached task returns so a superseding start
        /// cannot snapshot a stale `committedGenerations` after index/SQLite already advanced.
        let publishCommittedGeneration: @MainActor @Sendable (UInt64) -> Void = { [weak self] gen in
            self?.committedGenerations[locationId] = gen
        }
        /// Re-read committed at discard time (not a start-time snapshot) so complete-during-supersede
        /// keeps the newly committed tree instead of an older one.
        let latestCommittedGeneration: @MainActor @Sendable () -> UInt64? = { [weak self] in
            self?.committedGenerations[locationId]
        }

        let task = Task.detached(priority: .utility) {
            let applier = CoalescingApplier(index: index, generation: generation)
            var outcome: ScanOutcome = .complete

            do {
                try Task.checkCancellation()
                try await source.enumerate(
                    location: locationSnapshot,
                    generation: generation,
                    onBatch: { batch in
                        guard !Task.isCancelled else { return }
                        await applier.enqueue(batch)
                    },
                    onProgress: { p in
                        guard !Task.isCancelled else { return }
                        await setProgress(p)
                    }
                )
                try Task.checkCancellation()
                await applier.flush()
            } catch is CancellationError {
                await applier.flush()
                outcome = .cancelled
            } catch {
                await applier.flush()
                // Keep partial results; surface reason via progress path string for diagnostics.
                let message = error.localizedDescription
                await setProgress(
                    ScanProgress(
                        dirsVisited: 0,
                        filesVisited: 0,
                        bytesSeen: 0,
                        currentPath: "error: \(message)"
                    )
                )
                outcome = .failed
            }

            if isFull {
                switch outcome {
                case .complete:
                    // Drop older generations; keep the newly completed one.
                    await index.discardGeneration(locationId: locationId, keeping: generation)
                    let nodes = await index.nodes(for: locationId)
                    try? await store.save(nodes: nodes)
                    // Commit before return so awaiters / superseding starts observe it.
                    await publishCommittedGeneration(generation)
                case .cancelled, .failed:
                    // Rescan cancel/fail: drop incomplete new gen, keep last committed tree.
                    // First scan cancel/fail: keep partial new gen.
                    // Use current committed (MainActor hop), not a start-time snapshot.
                    let keeping = await latestCommittedGeneration()
                    if let keeping {
                        await index.discardGeneration(locationId: locationId, keeping: keeping)
                    }
                }
            } else if outcome == .complete {
                let nodes = await index.nodes(for: locationId)
                try? await store.save(nodes: nodes)
            }

            return outcome
        }

        activeTasks[location.id] = task
        let outcome = await task.value

        // Generation bookkeeping even when superseded: complete CAS; cancel/fail CAS-restores.
        if isFull {
            switch outcome {
            case .complete:
                // Idempotent if detached task already published; still safe if hop was skipped.
                committedGenerations[location.id] = generation
                // CAS: never clobber a newer start that already advanced `generations` past us.
                let current = generations[location.id] ?? 0
                if current <= generation {
                    generations[location.id] = generation
                }
            case .cancelled, .failed:
                // Compare-and-set: only restore if we still own this abandoned in-flight gen number.
                // (A later start may have already advanced `generations` past us.)
                // Re-read committed at discard time (may have been raised by a completing peer).
                if generations[location.id] == generation {
                    if let committed = committedGenerations[location.id] {
                        generations[location.id] = committed
                    }
                    // else first-scan cancel/fail: leave generations at partial in-flight gen
                }
            }
        }

        // Only the current owner may clear activeTasks and apply terminal scanState.
        guard startTokens[location.id] == token else { return }

        if activeTasks[location.id] == task {
            activeTasks[location.id] = nil
        }

        var finished = working
        switch outcome {
        case .complete:
            finished.scanState = .complete
            finished.lastScannedAt = Date()
        case .cancelled:
            finished.scanState = .cancelled
        case .failed:
            finished.scanState = .failed
        }
        onLocationUpdate?(finished)
    }

    func cancel(locationId: UUID) {
        activeTasks[locationId]?.cancel()
    }

    // MARK: - Concurrency gate (max concurrent location scans)

    private func acquireSlot() async {
        while activeScanCount >= maxConcurrent {
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                slotWaiters.append(cont)
            }
        }
        activeScanCount += 1
    }

    private func releaseSlot() {
        activeScanCount -= 1
        if !slotWaiters.isEmpty {
            let cont = slotWaiters.removeFirst()
            cont.resume()
        }
    }
}

// MARK: - Outcome

private enum ScanOutcome: Sendable {
    case complete
    case cancelled
    case failed
}

// MARK: - Coalesced batch apply (≤ ~100 ms)

private actor CoalescingApplier {
    private let index: ScanIndex
    private let generation: UInt64
    private let minInterval: Duration
    private var pending: [StorageNode] = []
    private var lastFlush: ContinuousClock.Instant

    init(index: ScanIndex, generation: UInt64, minInterval: Duration = .milliseconds(100)) {
        self.index = index
        self.generation = generation
        self.minInterval = minInterval
        self.lastFlush = ContinuousClock.now
    }

    func enqueue(_ batch: [StorageNode]) async {
        guard !batch.isEmpty else { return }
        pending.append(contentsOf: batch)
        let now = ContinuousClock.now
        if now - lastFlush >= minInterval {
            await flush()
        }
    }

    func flush() async {
        guard !pending.isEmpty else { return }
        let batch = pending
        pending = []
        lastFlush = ContinuousClock.now
        await index.apply(batch: batch, generation: generation)
    }
}
