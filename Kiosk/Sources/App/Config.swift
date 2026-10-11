import Foundation

enum Config {
    static let squareApplicationID = value("SquareApplicationID")
    static let accessToken = value("SquareAccessToken")
    static let locationID = value("SquareLocationID")
    static let categoryName = value("SquareCategoryName")
    static let eventName = value("KioskEventName") ?? "Tech Club Ice Cream"

    private static func value(_ key: String) -> String? {
        guard let raw = Bundle.main.object(forInfoDictionaryKey: key) as? String else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty || trimmed.hasPrefix("$(") ? nil : trimmed
    }
}
