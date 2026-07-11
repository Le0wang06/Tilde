import Foundation
import IOKit.ps

public struct BatteryProvider: MetricProvider {
    public init() {}

    public func fetchSnapshot() async throws -> BatteryReading {
        try Task.checkCancellation()
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else {
            throw MetricError.unavailable("IOKit power source information is unavailable")
        }

        for source in sources {
            guard let raw = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue(),
                  let description = raw as? [String: Any],
                  description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType else { continue }

            let current = description[kIOPSCurrentCapacityKey] as? Double
            let maximum = description[kIOPSMaxCapacityKey] as? Double
            let percentage = current.flatMap { value in
                maximum.flatMap { $0 > 0 ? value / $0 * 100 : nil }
            }
            let state = description[kIOPSPowerSourceStateKey] as? String
            let charging = description[kIOPSIsChargingKey] as? Bool
            let minutes = description[kIOPSTimeToEmptyKey] as? Int

            return BatteryReading(
                percent: percentage,
                isCharging: charging,
                isOnACPower: state == kIOPSACPowerValue,
                estimatedMinutesRemaining: minutes.flatMap { $0 > 0 ? $0 : nil }
            )
        }

        throw MetricError.unavailable("No internal battery was detected")
    }
}
