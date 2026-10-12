import SwiftUI
import UIKit
import WebKit

struct StaffWebView: View {
    let onExit: () -> Void
    @State private var model = StaffWebModel()

    var body: some View {
        ZStack {
            Theme.background
            if let url = model.url {
                StaffWebContainer(model: model, url: url, onExit: onExit)
            }
            if let failure = model.failure {
                StaffOfflineView(model: model, failure: failure)
            }
        }
        .ignoresSafeArea()
        .onAppear { UIApplication.shared.isIdleTimerDisabled = true }
    }
}

@Observable
@MainActor
final class StaffWebModel {
    struct Failure: Equatable {
        let reason: String
        let retriable: Bool
    }

    let url: URL? = BoothConfig.publicBaseURL?.appending(path: "staff/\(BoothConfig.staffPage)")
    var failure: Failure?
    var retryAt: Date?
    @ObservationIgnored var reload: (() -> Void)?
    @ObservationIgnored private var failures = 0
    @ObservationIgnored private var retryTask: Task<Void, Never>?

    init() {
        if url == nil { failure = Failure(reason: "BOOTH_URL is not set, so this iPad doesn't know where the booth is. Set it in Config/Local.xcconfig and rebuild.", retriable: false) }
    }

    var host: String { url?.host() ?? "" }

    func loaded() {
        retryTask?.cancel()
        failures = 0
        failure = nil
        retryAt = nil
    }

    func failed(_ reason: String) {
        guard url != nil else { return }
        failure = Failure(reason: reason, retriable: true)
        failures += 1
        let delay = BoothBackoff.delay(failures: failures, cap: 30)
        retryAt = Date().addingTimeInterval(delay)
        retryTask?.cancel()
        retryTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            self?.retry()
        }
    }

    func retry() {
        retryTask?.cancel()
        retryAt = nil
        reload?()
    }
}

private struct StaffOfflineView: View {
    let model: StaffWebModel
    let failure: StaffWebModel.Failure

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: failure.retriable ? "wifi.slash" : "exclamationmark.triangle")
                .font(.system(size: 72, weight: .semibold))
                .foregroundStyle(Theme.textSecondary)
            Text(failure.retriable ? "Can't reach the booth" : "No booth address")
                .font(Theme.sans(40, .bold))
                .foregroundStyle(Theme.text)
            if failure.retriable {
                Text(model.host)
                    .font(Theme.sans(22, .semibold))
                    .foregroundStyle(Theme.text)
            }
            Text(failure.reason)
                .font(Theme.sans(20))
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 560)
            if failure.retriable {
                Button { model.retry() } label: { Text("Retry now") }
                    .buttonStyle(.glassCTA(height: 88, fontSize: 30))
                    .padding(.top, 16)
                if let retryAt = model.retryAt {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        let seconds = max(0, Int(retryAt.timeIntervalSince(context.date).rounded(.up)))
                        Text("Retrying in \(seconds) s")
                            .font(Theme.sans(18))
                            .foregroundStyle(Theme.textSecondary)
                    }
                }
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.background)
    }
}

private struct StaffWebContainer: UIViewRepresentable {
    static let messageHandler = "boothApp"

    let model: StaffWebModel
    let url: URL
    let onExit: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(model: model, url: url, onExit: onExit) }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.mediaTypesRequiringUserActionForPlayback = []
        configuration.allowsInlineMediaPlayback = true
        configuration.applicationNameForUserAgent = "BoothStaffApp/1"
        configuration.websiteDataStore = .default()
        configuration.userContentController.add(WeakMessageHandler(context.coordinator), name: Self.messageHandler)
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.allowsLinkPreview = false
        webView.allowsBackForwardNavigationGestures = false
        webView.scrollView.bounces = false
        webView.scrollView.bouncesZoom = false
        webView.scrollView.minimumZoomScale = 1
        webView.scrollView.maximumZoomScale = 1
        webView.scrollView.pinchGestureRecognizer?.isEnabled = false
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.isOpaque = false
        webView.backgroundColor = .clear
        #if DEBUG
        webView.isInspectable = true
        #endif
        context.coordinator.webView = webView
        context.coordinator.start()
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    static func dismantleUIView(_ uiView: WKWebView, coordinator: Coordinator) {
        uiView.configuration.userContentController.removeScriptMessageHandler(forName: messageHandler)
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        let model: StaffWebModel
        let url: URL
        let onExit: () -> Void
        weak var webView: WKWebView?

        init(model: StaffWebModel, url: URL, onExit: @escaping () -> Void) {
            self.model = model
            self.url = url
            self.onExit = onExit
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.frameInfo.isMainFrame, message.frameInfo.securityOrigin.host == url.host(),
                  (message.body as? [String: Any])?["type"] as? String == "exitStaffMode" else { return }
            onExit()
        }

        func start() {
            model.reload = { [weak self] in self?.load() }
            load()
        }

        private func load() {
            guard let webView else { return }
            Task {
                await StaffSession.signInIfNeeded()
                webView.load(URLRequest(url: url))
            }
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse) async -> WKNavigationResponsePolicy {
            if navigationResponse.isForMainFrame, let http = navigationResponse.response as? HTTPURLResponse {
                if http.statusCode >= 500 {
                    model.failed("The booth server answered with an error (HTTP \(http.statusCode)).")
                    return .cancel
                }
            }
            return .allow
        }

        func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
            model.loaded()
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            report(error)
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            report(error)
        }

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            webView.reload()
        }

        private func report(_ error: Error) {
            let nsError = error as NSError
            if nsError.domain == NSURLErrorDomain, nsError.code == NSURLErrorCancelled { return }
            if nsError.domain == "WebKitErrorDomain", nsError.code == 102 { return }
            model.failed(Self.describe(nsError))
        }

        private static func describe(_ error: NSError) -> String {
            guard error.domain == NSURLErrorDomain else { return error.localizedDescription }
            switch error.code {
            case NSURLErrorNotConnectedToInternet, NSURLErrorDataNotAllowed: return "This iPad has no internet connection."
            case NSURLErrorTimedOut: return "The booth took too long to answer."
            case NSURLErrorCannotFindHost, NSURLErrorDNSLookupFailed: return "The booth's address could not be found."
            case NSURLErrorCannotConnectToHost, NSURLErrorNetworkConnectionLost: return "The connection to the booth was refused or dropped."
            case NSURLErrorSecureConnectionFailed, NSURLErrorServerCertificateUntrusted, NSURLErrorServerCertificateHasBadDate:
                return "A secure connection to the booth could not be made."
            default: return error.localizedDescription
            }
        }
    }
}

/// WKUserContentController keeps its handlers alive, which would otherwise keep the coordinator alive too.
@MainActor
private final class WeakMessageHandler: NSObject, WKScriptMessageHandler {
    weak var target: WKScriptMessageHandler?

    init(_ target: WKScriptMessageHandler) {
        self.target = target
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(userContentController, didReceive: message)
    }
}

enum StaffSession {
    private static let cookieName = "booth_staff"
    private static let deviceKey = "boothStaffDeviceID"
    private static let renewMargin: TimeInterval = 12 * 3600

    private struct Minted: Decodable {
        let token: String
        let expiresAt: Double
    }

    private static var deviceID: String {
        let defaults = UserDefaults.standard
        if let stored = defaults.string(forKey: deviceKey), !stored.isEmpty { return stored }
        let id = "staff-" + UUID().uuidString
        defaults.set(id, forKey: deviceKey)
        return id
    }

    @MainActor
    static func signInIfNeeded() async {
        guard let secret = BoothConfig.staffToken, let base = BoothConfig.publicBaseURL, let host = base.host() else { return }
        let store = WKWebsiteDataStore.default().httpCookieStore
        let existing = await store.allCookies()
        let cutoff = Date().addingTimeInterval(renewMargin)
        if existing.contains(where: { $0.name == cookieName && host.hasSuffix($0.domain.trimmingCharacters(in: CharacterSet(charactersIn: "."))) && ($0.expiresDate ?? .distantPast) > cutoff }) { return }
        guard let minted = await mint(base: base, secret: secret) else { return }
        let properties: [HTTPCookiePropertyKey: Any] = [
            .name: cookieName,
            .value: minted.token,
            .domain: host,
            .path: "/",
            .secure: "TRUE",
            .expires: Date(timeIntervalSince1970: minted.expiresAt / 1000),
            HTTPCookiePropertyKey("HttpOnly"): "TRUE",
            .sameSitePolicy: HTTPCookieStringPolicy.sameSiteStrict.rawValue
        ]
        guard let cookie = HTTPCookie(properties: properties) else { return }
        await store.setCookie(cookie)
    }

    private static func mint(base: URL, secret: String) async -> Minted? {
        var request = URLRequest(url: base.appending(path: "v1/staff/session"), timeoutInterval: 10)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(deviceID, forHTTPHeaderField: "X-Booth-Device")
        request.httpBody = try? JSONEncoder().encode(["pin": secret])
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return try? JSONDecoder().decode(Minted.self, from: data)
    }
}
