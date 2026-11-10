import Foundation
import HermesLensCore

/// Demo mode (Settings › Developer): the app runs without a Hermes server.
actor MockHermesClient: HermesClient {
    func health() async throws -> HermesHealth {
        try await Task.sleep(for: .milliseconds(180))
        return HermesHealth(isHealthy: true, detail: "Demo Luna is ready.")
    }

    func lensConfiguration() async throws -> HermesLensConfiguration { .fallback }
}
