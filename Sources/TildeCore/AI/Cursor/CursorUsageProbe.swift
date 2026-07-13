import Foundation

/// Best-effort Cursor plan usage from the local sign-in token + Cursor HTTPS APIs.
///
/// Reads `cursorAuth/accessToken` from Cursor's `state.vscdb` (read-only via `sqlite3`),
/// then calls `GetCurrentPeriodUsage` on `api2.cursor.sh`. Unofficial — may break if
/// Cursor changes storage or endpoints. Token is never logged.
public struct CursorUsageProbe: Sendable {
    private let spendLedger: DailySpendLedger

    public init(spendLedger: DailySpendLedger = .shared) {
        self.spendLedger = spendLedger
    }

    public func fetchSnapshot() async throws -> CursorUsageSnapshot {
        let token = try Self.readAccessToken()
        let membership = try? await Self.fetchMembershipType(token: token)
        let period = try await Self.fetchPeriodUsage(token: token)

        let used = period.totalPercentUsed
        let remaining: Int?
        if let used {
            remaining = max(0, min(100, Int((100.0 - used).rounded())))
        } else {
            remaining = nil
        }

        var notes: [String] = [
            "Token read from local Cursor state.vscdb (never stored by Tilde).",
            "Usage from unofficial Cursor API — shapes may change.",
        ]
        if period.hitLimit {
            notes.append("Included plan usage limit reached (bonus may still apply).")
        }

        var dailySpend: DailySpendReading?
        if let cumulativeCents = period.totalSpendCents,
           let periodID = period.billingCycleID {
            do {
                dailySpend = try await spendLedger.record(
                    provider: .cursor,
                    cumulativeCents: cumulativeCents,
                    periodID: periodID
                )
                notes.append("Today's Cursor spend is the locally observed delta of its monetary billing meter.")
            } catch {
                notes.append("Cursor spend tracking unavailable: \(error.localizedDescription)")
            }
        } else {
            notes.append("Cursor did not return a monetary billing meter for daily tracking.")
        }

        return CursorUsageSnapshot(
            remainingPercent: remaining,
            usedPercent: used,
            planName: membership ?? period.planHint,
            billingCycleEnd: period.billingCycleEnd,
            displayMessage: period.displayMessage,
            dailySpend: dailySpend,
            notes: notes
        )
    }

    private static func readAccessToken() throws -> String {
        let db = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Cursor/User/globalStorage/state.vscdb")
        guard FileManager.default.fileExists(atPath: db.path) else {
            throw CursorUsageError.databaseMissing
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = [
            db.path,
            "SELECT value FROM ItemTable WHERE key = 'cursorAuth/accessToken' LIMIT 1;",
        ]
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw CursorUsageError.databaseReadFailed
        }
        let token = String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !token.isEmpty else { throw CursorUsageError.tokenMissing }
        return token
    }

    private static func fetchPeriodUsage(token: String) async throws -> PeriodUsage {
        var request = URLRequest(
            url: URL(string: "https://api2.cursor.sh/aiserver.v1.DashboardService/GetCurrentPeriodUsage")!
        )
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("1", forHTTPHeaderField: "Connect-Protocol-Version")
        request.httpBody = Data("{}".utf8)
        request.timeoutInterval = 12

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw CursorUsageError.badResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            throw CursorUsageError.httpStatus(http.statusCode)
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CursorUsageError.badResponse
        }

        let planUsage = json["planUsage"] as? [String: Any]
        let totalPercent = (planUsage?["totalPercentUsed"] as? Double)
            ?? (planUsage?["totalPercentUsed"] as? NSNumber)?.doubleValue
        let displayMessage = (json["autoModelSelectedDisplayMessage"] as? String)
            ?? (json["displayMessage"] as? String)
        let hitLimit = (json["displayMessage"] as? String)?.localizedCaseInsensitiveContains("limit") == true
        let totalSpendCents = integerValue(planUsage?["totalSpend"])

        let endMillis: Double?
        if let value = json["billingCycleEnd"] as? String {
            endMillis = Double(value)
        } else if let value = json["billingCycleEnd"] as? Double {
            endMillis = value
        } else if let value = json["billingCycleEnd"] as? NSNumber {
            endMillis = value.doubleValue
        } else {
            endMillis = nil
        }
        let endDate = endMillis.map { Date(timeIntervalSince1970: $0 / 1000.0) }

        return PeriodUsage(
            totalPercentUsed: totalPercent,
            billingCycleEnd: endDate,
            billingCycleID: stringValue(json["billingCycleStart"]),
            totalSpendCents: totalSpendCents,
            displayMessage: displayMessage,
            hitLimit: hitLimit,
            planHint: nil
        )
    }

    private static func integerValue(_ value: Any?) -> Int? {
        if let value = value as? Int { return value }
        if let value = value as? NSNumber { return Int(value.doubleValue.rounded()) }
        if let value = value as? String, let number = Double(value) { return Int(number.rounded()) }
        return nil
    }

    private static func stringValue(_ value: Any?) -> String? {
        if let value = value as? String { return value }
        if let value = value as? NSNumber { return value.stringValue }
        return nil
    }

    private static func fetchMembershipType(token: String) async throws -> String? {
        var request = URLRequest(url: URL(string: "https://api2.cursor.sh/auth/full_stripe_profile")!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 10
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            return nil
        }
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        return (json?["membershipType"] as? String)
            ?? (json?["individualMembershipType"] as? String)
    }

    private struct PeriodUsage {
        var totalPercentUsed: Double?
        var billingCycleEnd: Date?
        var billingCycleID: String?
        var totalSpendCents: Int?
        var displayMessage: String?
        var hitLimit: Bool
        var planHint: String?
    }
}

public enum CursorUsageError: Error, LocalizedError {
    case databaseMissing
    case databaseReadFailed
    case tokenMissing
    case badResponse
    case httpStatus(Int)

    public var errorDescription: String? {
        switch self {
        case .databaseMissing:
            return "Cursor state database not found — is Cursor installed and signed in?"
        case .databaseReadFailed:
            return "Could not read Cursor auth database"
        case .tokenMissing:
            return "No Cursor access token — sign in to Cursor first"
        case .badResponse:
            return "Unexpected Cursor usage response"
        case .httpStatus(let code):
            return "Cursor usage HTTP \(code)"
        }
    }
}
