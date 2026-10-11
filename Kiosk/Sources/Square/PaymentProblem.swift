import Foundation
import SquareMobilePaymentsSDK

/// Everything a customer can be told about a payment that didn't finish. Technical detail goes to the log;
/// these strings are all a passer-by ever reads.
enum PaymentProblem: Equatable {
    case cardDidNotGoThrough
    case timedOut
    case offline
    case readerNotReady
    case paymentsPaused
    case needsStaff
    case stillFinishing
    case paidWithoutOrder

    var title: String {
        switch self {
        case .cardDidNotGoThrough: "Your payment didn't go through"
        case .timedOut: "That took a little too long"
        case .offline: "We can't reach the internet"
        case .readerNotReady: "The card reader isn't ready"
        case .paymentsPaused: "Card payments are paused"
        case .needsStaff: "We can't take cards right now"
        case .stillFinishing: "Just a moment"
        case .paidWithoutOrder: "Your payment went through"
        }
    }

    var details: [String] {
        switch self {
        case .cardDidNotGoThrough:
            ["Your card wasn't charged.", "Please try again, or use a different card."]
        case .timedOut:
            ["Your card wasn't charged.", "Tap Check Out to try again."]
        case .offline, .readerNotReady, .paymentsPaused, .needsStaff:
            ["Your card wasn't charged.", "Your order is saved. Please ask a staff member for help."]
        case .stillFinishing:
            ["We're still finishing the last payment. Please try again in a few seconds."]
        case .paidWithoutOrder:
            ["Please show this to a staff member so they can make your order."]
        }
    }

    /// `startPayment` failures. Declines, insufficient funds, gift card balance and card read errors never
    /// arrive here: Square's own payment screen shows them and lets the buyer retry or cancel.
    init(paymentError error: Error) {
        let nsError = error as NSError
        guard nsError.domain == Self.paymentErrorDomain,
              let code = PaymentError(rawValue: nsError.code)
        else {
            self = Self(networkError: error) ?? .cardDidNotGoThrough
            return
        }
        switch code {
        case .timedOut: self = .timedOut
        case .noNetwork: self = .offline
        case .unsupportedMode: self = .paymentsPaused
        case .paymentAlreadyInProgress: self = .stillFinishing
        case .offlineStoredAmountExceeded, .offlineTransactionAmountExceeded: self = .offline
        case .deviceTimeDoesNotMatchServerTime, .invalidPaymentParameters, .invalidPaymentSource,
             .locationPermissionNeeded, .merchantNotOptedIntoOfflineProcessing, .notAuthorized,
             .sandboxUnsupportedForOfflineProcessing, .unexpected, .trackingConsentIsPending,
             .paymentAttemptIdReused:
            self = .needsStaff
        @unknown default: self = .cardDidNotGoThrough
        }
    }

    /// `SQMPPaymentErrorDomain` from the SDK header, which Swift doesn't import.
    static let paymentErrorDomain = "MobilePaymentsSDKAPI.PaymentError"

    static func paymentError(_ code: PaymentError) -> NSError {
        NSError(domain: paymentErrorDomain, code: code.rawValue)
    }

    /// CreateOrder failures happen before the card is touched.
    init(orderError error: Error) {
        self = Self(networkError: error) ?? .needsStaff
    }

    private init?(networkError error: Error) {
        guard let urlError = error as? URLError else { return nil }
        switch urlError.code {
        case .timedOut: self = .timedOut
        case .notConnectedToInternet, .networkConnectionLost, .cannotFindHost, .cannotConnectToHost,
             .dnsLookupFailed, .internationalRoamingOff, .dataNotAllowed, .secureConnectionFailed:
            self = .offline
        default: return nil
        }
    }
}

/// Debug triggers for every customer-visible failure, from `-kioskForceError <name>` or the debug bar.
/// Each one feeds a representative error through the same mapping a real failure takes.
enum ForcedError: String, CaseIterable, Identifiable {
    case declined
    case timeout
    case offline
    case paymentOffline
    case notConfigured
    case notAuthorized
    case noReader
    case readerFailedToStart
    case screenShared
    case notFullScreen
    case unsupportedMode
    case locationPermission
    case orderRejected
    case alreadyInProgress
    case paidWithoutOrder
    case canceled
    case assets

    var id: String { rawValue }

    var label: String {
        switch self {
        case .declined: "Card didn't go through"
        case .timeout: "Payment timed out"
        case .offline: "Offline (creating order)"
        case .paymentOffline: "Offline (during payment)"
        case .notConfigured: "Square not configured"
        case .notAuthorized: "Square not authorized"
        case .noReader: "No card reader"
        case .readerFailedToStart: "Reader failed to start"
        case .screenShared: "Screen recorded or mirrored"
        case .notFullScreen: "Not full screen"
        case .unsupportedMode: "unsupportedMode from Square"
        case .locationPermission: "Location permission needed"
        case .orderRejected: "CreateOrder rejected"
        case .alreadyInProgress: "Payment already in progress"
        case .paidWithoutOrder: "Paid without an order"
        case .canceled: "Customer canceled"
        case .assets: "3D assets failed (relaunch)"
        }
    }
}
