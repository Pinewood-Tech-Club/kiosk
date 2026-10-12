import Foundation
import Observation
import UIKit

enum HelpReason: String, Sendable {
    case button
    case paymentFailed = "payment_failed"
    case noReader = "no_reader"
    case idle
}

@Observable
@MainActor
final class BoothLink {
    private struct SoldOutSnapshot: Codable {
        var rev: Int
        var soldOut: [String]
        var vessels: [String]?
        var toppings: [String]?
    }

    private static let kioskOpenKey = "boothKioskOpen"
    private static let debugKey = "boothKioskDebug"
    private static let nameKey = "boothKioskName"
    private static let soldOutKey = "boothSoldOutState"
    private static let idleLimit: TimeInterval = 60
    private static let helpRateLimit: TimeInterval = 30
    private static let uploadInterval: TimeInterval = 15
    private static let healthDebounce: TimeInterval = 2
    private static let healthRefresh: TimeInterval = 60
    private static let sessionInterval: TimeInterval = 0.25
    private static let keptResults = 20
    private static let rememberedCommands = 500

    private(set) var connectionState: BoothConnection.ConnectionState = .idle
    private(set) var soldOut: Set<Flavor>
    private(set) var soldOutVessels: Set<Vessel>
    private(set) var soldOutToppings: Set<Topping>
    private(set) var kioskOpen: Bool
    private(set) var debugEnabled: Bool
    private(set) var kioskName: String?
    private(set) var helpBannerVisible = false
    private(set) var serverFeatures: Set<String> = []
    @ObservationIgnored private(set) var api: BoothAPI?
    private(set) var assistActive = false

    @ObservationIgnored private weak var app: AppModel?
    @ObservationIgnored private var square: SquareService?
    @ObservationIgnored private var started = false
    @ObservationIgnored private var connection: BoothConnection?
    @ObservationIgnored private var shipper: LogShipper?
    @ObservationIgnored private let outbox = BoothOutbox()
    @ObservationIgnored private var bannerTask: Task<Void, Never>?
    @ObservationIgnored private var lastUpload = Date.distantPast
    @ObservationIgnored private var lastTouch = Date()
    @ObservationIgnored private var idleSent = false
    @ObservationIgnored private var lastHelpSent: [HelpReason: Date] = [:]
    @ObservationIgnored private var lastHealth: KioskHealth?
    @ObservationIgnored private var lastHealthQueued = Date.distantPast
    @ObservationIgnored private var forceHealth = false
    @ObservationIgnored private var deviceID: String?
    @ObservationIgnored private var assistExpiry = Date.distantPast
    @ObservationIgnored private var lastSession: AssistSession?
    @ObservationIgnored private var commandQueue: [AssistCommand] = []
    @ObservationIgnored private var runningCommands = false
    @ObservationIgnored private var runningCommandID: String?
    @ObservationIgnored private var handledCommands: [String: AssistSession.Result] = [:]
    @ObservationIgnored private var handledOrder: [String] = []
    @ObservationIgnored private var assistResults: [AssistSession.Result] = []

    init() {
        let stored = UserDefaults.standard.data(forKey: Self.soldOutKey).flatMap { try? JSONDecoder().decode(SoldOutSnapshot.self, from: $0) }
        soldOut = Set((stored?.soldOut ?? []).compactMap(Flavor.init(rawValue:)))
        soldOutVessels = Set((stored?.vessels ?? []).compactMap(Vessel.init(rawValue:)))
        soldOutToppings = Set((stored?.toppings ?? []).compactMap(Topping.init(rawValue:)))
        kioskOpen = UserDefaults.standard.object(forKey: Self.kioskOpenKey) as? Bool ?? true
        debugEnabled = UserDefaults.standard.bool(forKey: Self.debugKey)
        kioskName = UserDefaults.standard.string(forKey: Self.nameKey)
    }

    var isEnabled: Bool { BoothConfig.current != nil }

    func isSoldOut(_ flavor: Flavor) -> Bool { soldOut.contains(flavor) }
    func isSoldOut(_ vessel: Vessel) -> Bool { soldOutVessels.contains(vessel) }
    func isSoldOut(_ topping: Topping) -> Bool { soldOutToppings.contains(topping) }
    var outOfVessels: Bool { Vessel.allCases.allSatisfy(soldOutVessels.contains) }

    func start(square: SquareService, app: AppModel) {
        guard !started else { return }
        started = true
        self.square = square
        self.app = app
        guard let config = BoothConfig.current else {
            square.record("Booth: link disabled (BOOTH_URL or BOOTH_TOKEN not set)")
            return
        }
        UIDevice.current.isBatteryMonitoringEnabled = true
        observeTouches()
        observeActivation()
        Task { [weak self] in await self?.bootstrap(config) }
    }

    func tapHelpButton() {
        guard !helpBannerVisible else { return }
        helpBannerVisible = true
        requestHelp(.button, message: "Customer pressed the help button on the \(app?.screen.boothName ?? "builder") screen")
        bannerTask?.cancel()
        bannerTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(6))
            guard !Task.isCancelled else { return }
            self?.helpBannerVisible = false
        }
    }

    func requestHelp(_ reason: HelpReason, message: String) {
        guard isEnabled else { return }
        let now = Date()
        if reason != .button, let last = lastHelpSent[reason], now.timeIntervalSince(last) < Self.helpRateLimit { return }
        lastHelpSent[reason] = now
        log("Booth: help requested (\(reason.rawValue)): \(message)")
        let outbox = outbox
        Task { await outbox.enqueueHelp(reason: reason.rawValue, message: message) }
    }

    func paymentFailed(_ problem: PaymentProblem) {
        requestHelp(.paymentFailed, message: "Payment failed: \(problem.title)")
    }

    func checkReaderBeforePayment() {
        guard let app, let square, !app.simulatePayment, app.forcedError == nil, square.isConfigured,
              !UserDefaults.standard.bool(forKey: "kioskNoSquare"),
              !square.readers.contains(where: { $0.statusInfo.status == .ready }) else { return }
        requestHelp(.noReader, message: "No card reader is ready at checkout")
    }

    func orderPaid(_ receipt: Receipt, quote: OrderQuote) {
        let order = BoothOrder(receipt: receipt, quote: quote)
        log("Booth: order #\(order.orderNumber) queued for upload")
        let outbox = outbox
        Task { await outbox.enqueueOrder(order) }
    }

    private func log(_ message: String) {
        square?.record(message)
    }

    private func bootstrap(_ config: BoothConfig) async {
        let deviceID = await outbox.device()
        self.deviceID = deviceID
        let api = BoothAPI(config: config, deviceID: deviceID)
        self.api = api
        square?.attachBooth(api)
        await outbox.attach(api: api) { [weak self] message in
            Task { @MainActor in self?.log(message) }
        }

        let connection = BoothConnection(api: api) { [weak self] message in self?.log(message) }
        connection.screen = { [weak self] in self?.app?.screen.boothName ?? "roleSetup" }
        connection.name = { BoothConfig.kioskName }
        connection.onState = { [weak self] state in self?.applyState(state) }
        connection.onConnectionChange = { [weak self] state in self?.connectionChanged(state) }
        connection.onAssist = { [weak self] active, expiresIn in self?.assistChanged(active, expiresIn: expiresIn) }
        connection.onCommand = { [weak self] command in self?.receive(command) }
        self.connection = connection

        shipper = LogShipper(api: api, fileURL: SquareService.logFileURL) { [weak self] message in
            Task { @MainActor in self?.log(message) }
        }
        log("Booth: link enabled for \(config.baseURL.host() ?? "server") as \(deviceID.prefix(8))")
        connection.start()
        Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                self?.tick()
            }
        }
        Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Self.sessionInterval))
                self?.publishSession()
            }
        }
    }

    private func publishSession() {
        guard connectionState == .connected, let app, let connection else { return }
        let session = app.assistSession(assisted: assistActive, results: assistResults)
        guard session != lastSession, connection.send(session: session) else { return }
        lastSession = session
    }

    private func assistChanged(_ active: Bool, expiresIn: TimeInterval) {
        assistExpiry = active ? Date().addingTimeInterval(expiresIn + 5) : .distantPast
        guard active != assistActive else { return }
        assistActive = active
        log("Booth: staff assist " + (active ? "started" : "ended"))
    }

    private func receive(_ command: AssistCommand) {
        guard !command.id.isEmpty else { return }
        if let done = handledCommands[command.id] {
            record(AssistSession.Result(id: command.id, status: done.status == "applied" ? "duplicate" : done.status, message: done.message))
            return
        }
        guard command.id != runningCommandID, !commandQueue.contains(where: { $0.id == command.id }) else { return }
        commandQueue.append(command)
        guard !runningCommands else { return }
        runningCommands = true
        Task { [weak self] in await self?.runCommands() }
    }

    private func runCommands() async {
        while !commandQueue.isEmpty, let app {
            let command = commandQueue.removeFirst()
            runningCommandID = command.id
            lastTouch = Date()
            idleSent = false
            let outcome = await app.applyAssist(command.op)
            let result: AssistSession.Result
            switch outcome {
            case .applied: result = AssistSession.Result(id: command.id, status: "applied", message: nil)
            case .rejected(let reason): result = AssistSession.Result(id: command.id, status: "rejected", message: reason)
            }
            log("Booth: assist \(command.op) from \(command.by ?? "staff"): \(result.status)" + (result.message.map { " (\($0))" } ?? ""))
            handledCommands[command.id] = result
            handledOrder.append(command.id)
            if handledOrder.count > Self.rememberedCommands {
                handledCommands[handledOrder.removeFirst()] = nil
            }
            runningCommandID = nil
            record(result)
        }
        runningCommands = false
    }

    private func record(_ result: AssistSession.Result) {
        assistResults.append(result)
        if assistResults.count > Self.keptResults { assistResults.removeFirst(assistResults.count - Self.keptResults) }
    }

    private func connectionChanged(_ state: BoothConnection.ConnectionState) {
        connectionState = state
        guard state == .connected else { return }
        Task { [weak self] in await self?.refreshFeatures() }
        lastSession = nil
        forceHealth = true
        lastUpload = .distantPast
        let outbox = outbox
        let shipper = shipper
        Task {
            await outbox.kick(resetBackoff: true)
            await shipper?.resetBackoff()
        }
    }

    private func refreshFeatures() async {
        struct Health: Decodable { let features: [String]? }
        guard let api else { return }
        do {
            let health: Health = try await api.get("/v1/health")
            let features = Set(health.features ?? [])
            if features != serverFeatures { log("Booth: server features " + features.sorted().joined(separator: ", ")) }
            serverFeatures = features
        } catch {
            log("Booth: health check failed (\((error as? BoothError)?.summary ?? error.localizedDescription))")
        }
    }

    private func applyState(_ state: BoothState) {
        if let epoch = state.epoch { adopt(epoch: epoch) }
        if let kiosks = state.kiosks {
            if let mine = kiosks.first(where: { $0.id == deviceID }) { applyOwnEntry(mine) }
        } else {
            setOpen(state.kioskOpen.open)
        }
        let flavors: Set<Flavor>
        var vessels = soldOutVessels
        var toppings = soldOutToppings
        if let supplies = state.supplies {
            let out = supplies.filter(\.soldOut)
            flavors = Set(out.filter { $0.kind == "flavor" }.compactMap { Flavor(rawValue: $0.id) })
            vessels = Set(out.filter { $0.kind == "vessel" }.compactMap { Vessel(rawValue: $0.id) })
            toppings = Set(out.filter { $0.kind == "topping" }.compactMap { Topping(rawValue: $0.id) })
        } else {
            flavors = Set(state.flavors.filter(\.soldOut).compactMap { Flavor(rawValue: $0.id) })
        }
        guard flavors != soldOut || vessels != soldOutVessels || toppings != soldOutToppings else { return }
        let vesselsChanged = vessels != soldOutVessels
        soldOut = flavors
        soldOutVessels = vessels
        soldOutToppings = toppings
        let snapshot = SoldOutSnapshot(rev: state.rev, soldOut: flavors.map(\.rawValue).sorted(),
                                       vessels: vessels.map(\.rawValue).sorted(), toppings: toppings.map(\.rawValue).sorted())
        UserDefaults.standard.set(try? JSONEncoder().encode(snapshot), forKey: Self.soldOutKey)
        let all = snapshot.soldOut + (snapshot.vessels ?? []) + (snapshot.toppings ?? []).map { "\($0) topping" }
        log("Booth: sold out is now " + (all.isEmpty ? "none" : all.joined(separator: ", ")))
        if vesselsChanged { app?.vesselsChanged() }
    }

    private func adopt(epoch: Int) {
        let known = BoothEpoch.known
        guard epoch > (known ?? 0) else {
            if known == nil { UserDefaults.standard.set(epoch, forKey: BoothEpoch.key) }
            return
        }
        let logEnd = LogShipper.size(of: SquareService.logFileURL)
        UserDefaults.standard.set(epoch, forKey: BoothEpoch.key)
        app?.resetOrderCounter()
        clearCachedFlags()
        handledCommands = [:]
        handledOrder = []
        assistResults = []
        lastSession = nil
        forceHealth = true
        let outbox = outbox
        let shipper = shipper
        Task {
            await shipper?.skip(to: logEnd)
            await outbox.purge(before: epoch)
        }
        log("Booth: reset to epoch \(epoch) by the booth")
    }

    private func clearCachedFlags() {
        let hadVessels = !soldOutVessels.isEmpty
        kioskOpen = true
        debugEnabled = false
        kioskName = nil
        soldOut = []
        soldOutVessels = []
        soldOutToppings = []
        for key in [Self.kioskOpenKey, Self.debugKey, Self.nameKey, Self.soldOutKey] {
            UserDefaults.standard.removeObject(forKey: key)
        }
        if hadVessels { app?.vesselsChanged() }
    }

    private func applyOwnEntry(_ entry: KioskEntry) {
        setOpen(entry.open)
        if entry.debug != debugEnabled {
            debugEnabled = entry.debug
            UserDefaults.standard.set(debugEnabled, forKey: Self.debugKey)
            log("Booth: debug tools turned " + (debugEnabled ? "on" : "off") + " by staff")
            if debugEnabled { app?.debugToolsTurnedOn() }
        }
        if entry.name != kioskName {
            kioskName = entry.name
            UserDefaults.standard.set(entry.name, forKey: Self.nameKey)
            log("Booth: staff pages call this kiosk \(entry.name)")
        }
    }

    private func setOpen(_ open: Bool) {
        guard open != kioskOpen else { return }
        kioskOpen = open
        UserDefaults.standard.set(kioskOpen, forKey: Self.kioskOpenKey)
        log("Booth: kiosk is now " + (kioskOpen ? "open" : "closed"))
    }

    private func observeTouches() {
        Task { [weak self] in
            for await _ in NotificationCenter.default.notifications(named: TouchObserver.didTouch) {
                guard let self else { return }
                lastTouch = Date()
                idleSent = false
            }
        }
    }

    private func observeActivation() {
        Task { [weak self] in
            for await _ in NotificationCenter.default.notifications(named: UIApplication.didBecomeActiveNotification) {
                guard let self else { return }
                let outbox = outbox
                Task { await outbox.kick(resetBackoff: true) }
            }
        }
    }

    private func tick() {
        let now = Date()
        if assistActive, now >= assistExpiry { assistChanged(false, expiresIn: 0) }
        checkIdle(now)
        queueHealth(now)
        if connectionState == .connected, now.timeIntervalSince(lastUpload) >= Self.uploadInterval, let shipper {
            lastUpload = now
            Task { await shipper.ship() }
        }
    }

    private func queueHealth(_ now: Date) {
        guard let app, let square else { return }
        let snapshot = BoothHealth.snapshot(square: square, screen: app.screen.boothName, simulatePayment: app.simulatePayment)
        let age = now.timeIntervalSince(lastHealthQueued)
        let changed = snapshot != lastHealth
        guard forceHealth || (changed && age >= Self.healthDebounce) || (connectionState == .connected && age >= Self.healthRefresh) else { return }
        forceHealth = false
        lastHealth = snapshot
        lastHealthQueued = now
        let outbox = outbox
        Task { await outbox.enqueueHealth(snapshot) }
    }

    private func checkIdle(_ now: Date) {
        guard !idleSent, let app, !app.isPaying, app.screen == .builder || app.screen == .name,
              !app.items.isEmpty || app.currentHasChoices,
              now.timeIntervalSince(lastTouch) >= Self.idleLimit else { return }
        idleSent = true
        requestHelp(.idle, message: "Customer has been idle for a minute mid-order on the \(app.screen.boothName) screen")
    }
}
