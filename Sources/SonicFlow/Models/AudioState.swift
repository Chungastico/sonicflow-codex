import Foundation
import Observation

/// Single source of truth for the UI. Engines push updates here; views observe.
@Observable
@MainActor
final class AudioState {
    var apps: [AudioApp] = []
    var masterVolume: Float = 1.0
    var isMasterMuted: Bool = false

    var isCodexAudible: Bool = false
    var isUserAudible: Bool = false
    var duckingEnabled: Bool = true
    var duckingAmount: Float = 0.90        // reduce Spotify to 10% during speech
    var duckingAttackMs: Double = 120
    var duckingReleaseMs: Double = 600

    /// When true, the master slider also drives the system output volume —
    /// so users get master control until Phase 3 per-app routing is solid.
    var masterControlsSystemVolume: Bool = true

    /// The user-perceived volume for an app, after master scaling and ducking.
    func effectiveVolume(for app: AudioApp) -> Float {
        guard !isMasterMuted, !app.isMuted else { return 0 }
        let isSpotify = app.id == "com.spotify.client" || (app.id == "com.test.music" && ProcessInfo.processInfo.environment["SONICFLOW_TEST"] == "1")
        let base: Float = isSpotify ? 1.0 : app.volume * (masterControlsSystemVolume ? 1.0 : masterVolume)
        if duckingEnabled, isAnyCommunicationActive, app.category != .communication {
            return base * (1.0 - duckingAmount)
        }
        return base
    }

    var isAnyCommunicationActive: Bool {
        isCodexAudible || isUserAudible
    }

    /// Replace or insert an app entry, preserving order.
    func upsert(_ app: AudioApp) {
        if let idx = apps.firstIndex(where: { $0.id == app.id }) {
            apps[idx] = app
        } else {
            apps.append(app)
        }
    }

    func remove(id: String) {
        apps.removeAll { $0.id == id }
    }

    func setVolume(_ value: Float, for id: String) {
        guard let idx = apps.firstIndex(where: { $0.id == id }) else { return }
        apps[idx].volume = max(0, min(1, value))
    }

    func setMuted(_ muted: Bool, for id: String) {
        guard let idx = apps.firstIndex(where: { $0.id == id }) else { return }
        apps[idx].isMuted = muted
    }
}
