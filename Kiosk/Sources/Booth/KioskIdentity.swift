import Foundation

/// The install's device id, shared with `BoothOutbox` (which sends it as `X-Booth-Device`). Its first four letters
/// and digits are the kiosk's tag, which the server also derives, so order references are unique across kiosks
/// without asking the server.
enum KioskIdentity {
    static let installIDKey = "boothInstallID"

    static var deviceID: String {
        let defaults = UserDefaults.standard
        if let stored = defaults.string(forKey: installIDKey), !stored.isEmpty { return stored }
        let id = UUID().uuidString
        defaults.set(id, forKey: installIDKey)
        return id
    }

    static var tag: String {
        let letters = deviceID.unicodeScalars.filter { $0.isASCII && CharacterSet.alphanumerics.contains($0) }
        let tag = String(String.UnicodeScalarView(letters.prefix(4))).uppercased()
        return tag.isEmpty ? "0000" : tag
    }

    static func orderRef(_ number: Int) -> String {
        "\(tag)-\(number)"
    }
}
