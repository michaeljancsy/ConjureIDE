//
//  TransportPushManager.swift
//  ConjureDSPExtension
//
//  Pushes DAW transport state (tempo, play state, beat position, time
//  signature, sample position) to subscribed custom-UI WebViews at ~30 Hz.
//
//  Independent of `AudioCaptureManager` so a UI that only wants tempo
//  doesn't spin up the audio capture pipeline (ring-buffer drains, FFT
//  setup, etc.). Consumer-counted: zero CPU when no UI calls
//  `ConjureDSP.transport.onChange()`.
//

import Combine
import Foundation
import os

/// One snapshot of host transport state. Hashable so the Timer tick can
/// dedupe-on-equal cheaply (skip the publish when nothing changed since
/// the last fire). All fields are scalar, total payload < 100 bytes when
/// JSON-encoded.
struct TransportSnapshot: Hashable {
    var tempo: Double
    var beatPosition: Double
    var samplePosition: Double
    var timeSigNumerator: Int32
    var timeSigDenominator: Int32
    var isPlaying: Bool

    static let zero = TransportSnapshot(
        tempo: 0,
        beatPosition: 0,
        samplePosition: 0,
        timeSigNumerator: 4,
        timeSigDenominator: 4,
        isPlaying: false
    )
}

/// Owns the latest transport snapshot (written by the audio thread,
/// read by a main-thread Timer) and publishes changes to any subscribed
/// custom-UI consumer. Mirrors the consumer-counted lifecycle pattern
/// used by `AudioCaptureManager`.
final class TransportPushManager {

    // MARK: - Published

    /// Fires whenever the snapshot has changed since the previous tick.
    /// On the first tick after a consumer subscribes the publisher fires
    /// once with the current snapshot to seed UI state.
    let transportPublisher = PassthroughSubject<TransportSnapshot, Never>()

    // MARK: - Snapshot storage (audio-thread writer, main-thread reader)

    /// Lock-protected mutable snapshot the audio thread writes into and
    /// the main-thread Timer reads. `os_unfair_lock`'s lock/unlock pair
    /// is allocation-free and a few cycles uncontended; the audio thread
    /// holds it for ~6 stores once per render block. Negligible.
    private var lock = os_unfair_lock_s()
    private var snapshot: TransportSnapshot = .zero

    /// Bumps every time `audioThreadStore` writes. The Timer reads it
    /// alongside the snapshot to detect "no change since last tick"
    /// without comparing all fields under the lock.
    private var generation: UInt64 = 0
    private var lastPublishedGeneration: UInt64 = 0
    private var lastPublishedSnapshot: TransportSnapshot? = nil
    /// Tracks whether the publisher has fired at least once since this
    /// consumer set became non-empty. Lets us send a seed snapshot on
    /// the first tick even when nothing has changed.
    private var didSeedAfterSubscribe: Bool = false

    // MARK: - Consumer ref-counting

    /// Active consumer ids. When non-empty, a Timer at ~30 Hz runs and
    /// drains the snapshot; when empty the Timer is invalidated. Same
    /// idempotent set-based pattern as `AudioCaptureManager.consumers`.
    private var consumers: Set<String> = []

    private var timer: Timer?

    /// Push frequency target. 30 Hz (~33 ms tick). Matches the doc-stated
    /// rate; trades a 16 ms worst-case latency for cheap idle behavior.
    static let pushFrequency: TimeInterval = 1.0 / 30.0

    // MARK: - Init / deinit

    init() {}

    deinit {
        timer?.invalidate()
    }

    // MARK: - Audio-thread API

    /// Called from the audio thread once per render callback right after
    /// the existing `dsp_kernel_set_transport` call. The audio thread
    /// already has these values as locals; we just stash them under a
    /// brief lock.
    ///
    /// Allocation-free, lock-held for ~6 stores. Audio-thread safe.
    func audioThreadStore(
        tempo: Double,
        beatPosition: Double,
        samplePosition: Double,
        timeSigNumerator: Int32,
        timeSigDenominator: Int32,
        isPlaying: Bool
    ) {
        os_unfair_lock_lock(&lock)
        snapshot.tempo = tempo
        snapshot.beatPosition = beatPosition
        snapshot.samplePosition = samplePosition
        snapshot.timeSigNumerator = timeSigNumerator
        snapshot.timeSigDenominator = timeSigDenominator
        snapshot.isPlaying = isPlaying
        generation &+= 1
        os_unfair_lock_unlock(&lock)
    }

    // MARK: - Main-thread API

    /// Register / unregister a consumer. Idempotent per-id.
    /// Empty→non-empty schedules the Timer; non-empty→empty cancels it.
    func setConsumer(id: String, active: Bool) {
        let wasActive = !consumers.isEmpty
        if active { consumers.insert(id) } else { consumers.remove(id) }
        let isActiveNow = !consumers.isEmpty
        guard wasActive != isActiveNow else { return }
        if isActiveNow {
            startTimer()
        } else {
            stopTimer()
        }
    }

    private func startTimer() {
        timer?.invalidate()
        // Reset seed flag so the first tick after subscribing fires once
        // with whatever the current snapshot is, even if it hasn't changed
        // since the previous lifetime.
        didSeedAfterSubscribe = false
        let t = Timer(timeInterval: Self.pushFrequency, repeats: true) { [weak self] _ in
            self?.tick()
        }
        // Common modes so the Timer keeps firing during gesture tracking
        // (slider drags, etc.) — same rationale as AudioCaptureManager's
        // displayLink.add(to: .main, forMode: .common).
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
        lastPublishedSnapshot = nil
        lastPublishedGeneration = 0
        didSeedAfterSubscribe = false
    }

    private func tick() {
        os_unfair_lock_lock(&lock)
        let gen = generation
        let snap = snapshot
        os_unfair_lock_unlock(&lock)

        // Publish if either: (a) we haven't seeded subscribers yet, or
        // (b) the snapshot changed since the last publish. Bare equality
        // on the Hashable struct does the diff.
        if !didSeedAfterSubscribe {
            didSeedAfterSubscribe = true
            lastPublishedGeneration = gen
            lastPublishedSnapshot = snap
            transportPublisher.send(snap)
            return
        }
        if gen == lastPublishedGeneration { return }
        if lastPublishedSnapshot == snap {
            // Audio thread bumped generation but values are identical
            // (e.g. host re-set the same tempo). Skip publish but track
            // generation so we don't re-compare next tick.
            lastPublishedGeneration = gen
            return
        }
        lastPublishedGeneration = gen
        lastPublishedSnapshot = snap
        transportPublisher.send(snap)
    }

    // MARK: - Test affordances

    var _test_consumerCount: Int { consumers.count }
    var _test_timerActive: Bool { timer != nil }
    func _test_simulateAudioThreadStore(_ snap: TransportSnapshot) {
        audioThreadStore(
            tempo: snap.tempo,
            beatPosition: snap.beatPosition,
            samplePosition: snap.samplePosition,
            timeSigNumerator: snap.timeSigNumerator,
            timeSigDenominator: snap.timeSigDenominator,
            isPlaying: snap.isPlaying
        )
    }
}
