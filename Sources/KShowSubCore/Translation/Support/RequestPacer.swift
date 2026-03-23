import Foundation

/// Simple async pacer that spaces request start times by a fixed interval.
actor RequestPacer {
    private let intervalNanoseconds: UInt64
    private var nextAllowedUptimeNanoseconds: UInt64

    init(requestsPerSecond: Double) {
        precondition(requestsPerSecond > 0, "requestsPerSecond must be positive")
        self.intervalNanoseconds = UInt64((1_000_000_000.0 / requestsPerSecond).rounded())
        self.nextAllowedUptimeNanoseconds = DispatchTime.now().uptimeNanoseconds
    }

    func acquire() async throws {
        let now = DispatchTime.now().uptimeNanoseconds
        let scheduled = max(now, nextAllowedUptimeNanoseconds)
        nextAllowedUptimeNanoseconds = scheduled &+ intervalNanoseconds

        if scheduled > now {
            try await Task.sleep(nanoseconds: scheduled - now)
        }
    }
}
