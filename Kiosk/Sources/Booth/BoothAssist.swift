import Foundation

enum AssistDestination: String, Sendable {
    case builder, summary, name
}

struct AssistCommand: Decodable, Equatable, Sendable {
    enum Op: Equatable, Sendable {
        case addScoop(item: String, flavor: Flavor)
        case removeScoop(item: String, flavor: Flavor)
        case setVessel(item: String, vessel: Vessel)
        case setTopping(item: String, topping: Topping, on: Bool)
        case addItem
        case removeItem(item: String)
        case setName(String)
        case navigate(AssistDestination)
        case startOver
        case unsupported(String)
    }

    let id: String
    let by: String?
    let op: Op

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        id = c.lenient(AnyKey("id"), "")
        by = c.lenientOptional(AnyKey("by"))
        let name: String = c.lenient(AnyKey("op"), "")
        let item: String = c.lenient(AnyKey("item"), "")
        let flavor = Flavor(rawValue: c.lenient(AnyKey("flavor"), ""))
        let vessel = Vessel(rawValue: c.lenient(AnyKey("vessel"), ""))
        let topping = Topping(rawValue: c.lenient(AnyKey("topping"), ""))
        switch name {
        case "addScoop": op = flavor.map { .addScoop(item: item, flavor: $0) } ?? .unsupported("This kiosk doesn't have that flavor")
        case "removeScoop": op = flavor.map { .removeScoop(item: item, flavor: $0) } ?? .unsupported("This kiosk doesn't have that flavor")
        case "setVessel": op = vessel.map { .setVessel(item: item, vessel: $0) } ?? .unsupported("Unknown cup or cone")
        case "setTopping":
            op = topping.map { .setTopping(item: item, topping: $0, on: c.lenient(AnyKey("on"), true)) }
                ?? .unsupported("This kiosk doesn't have that topping")
        case "addItem": op = .addItem
        case "removeItem": op = .removeItem(item: item)
        case "setName": op = .setName(c.lenient(AnyKey("name"), ""))
        case "navigate":
            op = AssistDestination(rawValue: c.lenient(AnyKey("to"), "")).map { .navigate($0) } ?? .unsupported("Unknown screen")
        case "startOver": op = .startOver
        default: op = .unsupported("This kiosk's app doesn't know \(name.isEmpty ? "that command" : name)")
        }
    }
}

struct AssistSession: Encodable, Equatable, Sendable {
    struct Item: Encodable, Equatable, Sendable {
        let id: String
        let vessel: String
        let flavors: [String]
        let toppings: [String]
        let cents: Int
        let current: Bool
        let inOrder: Bool
    }

    struct Result: Encodable, Equatable, Sendable {
        let id: String
        let status: String
        let message: String?
    }

    var screen: String
    var step: String?
    var editing: Bool
    var items: [Item]
    var customerName: String
    var totalCents: Int
    var paying: Bool
    var orderingOpen: Bool
    var assisted: Bool
    var maxScoops: Int
    var results: [Result]
}

struct AssistSessionMessage: Encodable, Sendable {
    let type = "session"
    let session: AssistSession
}
