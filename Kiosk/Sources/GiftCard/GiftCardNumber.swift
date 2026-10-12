import Foundation

enum GiftCardNumber {
    static let length = 16

    /// Square prints gift card codes as `sqgc://` plus the number; other barcodes in view are ignored.
    static func parse(_ scanned: String) -> String? {
        var text = scanned.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.lowercased().hasPrefix("sqgc://") { text.removeFirst("sqgc://".count) }
        let digits = text.filter { $0.isASCII && $0.isNumber }
        return digits.count == length ? digits : nil
    }

    static func grouped(_ digits: String) -> String {
        stride(from: 0, to: digits.count, by: 4).map { start in
            let from = digits.index(digits.startIndex, offsetBy: start)
            let to = digits.index(from, offsetBy: min(4, digits.count - start))
            return String(digits[from..<to])
        }.joined(separator: " ")
    }

    static func last4(_ digits: String) -> String { String(digits.suffix(4)) }
}
