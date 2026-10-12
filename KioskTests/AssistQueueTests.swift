import XCTest
@testable import Kiosk

final class AssistQueueTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    private func command(_ id: String, seq: Int? = nil, base: Int? = 0, after: [String] = [], stream: String? = "s1",
                         op: String = "setName", ref: String? = nil) -> AssistCommand {
        var json: [String: Any] = ["id": id, "op": op, "name": id, "kiosk": "k", "after": after]
        if let stream { json["stream"] = stream }
        if let seq { json["seq"] = seq }
        if let base { json["base"] = base }
        if let ref { json["ref"] = ref }
        let data = try! JSONSerialization.data(withJSONObject: json)
        return try! JSONDecoder().decode(AssistCommand.self, from: data)
    }

    private func drain(_ queue: inout AssistQueue<AssistCommand>, rejecting: Set<String> = []) -> [String] {
        var order: [String] = []
        while let item = queue.next() {
            order.append(item.id)
            let status = rejecting.contains(item.id) || queue.blocker(of: item) != nil ? "rejected" : "applied"
            queue.finish(item, AssistSession.Result(id: item.id, status: status, message: nil))
        }
        return order
    }

    func testDecodesOrderingFields() {
        let c = command("a", seq: 3, base: 1, after: ["x"], op: "addItem", ref: "00000000-0000-4000-8000-0000000000AA")
        XCTAssertEqual(c.stream, "s1")
        XCTAssertEqual(c.seq, 3)
        XCTAssertEqual(c.base, 1)
        XCTAssertEqual(c.after, ["x"])
        XCTAssertEqual(c.ref, UUID(uuidString: "00000000-0000-4000-8000-0000000000AA"))
        XCTAssertEqual(c.op, .addItem)
        let old = command("b", seq: nil, base: nil, stream: nil, ref: "nope")
        XCTAssertNil(old.stream)
        XCTAssertNil(old.seq)
        XCTAssertNil(old.ref)
    }

    func testAppliesInSequenceOrderWhateverTheArrivalOrder() {
        var queue = AssistQueue<AssistCommand>()
        for seq in [2, 4, 3] {
            guard case .queued = queue.receive(command("c\(seq)", seq: seq), now: start) else { return XCTFail("not queued") }
        }
        XCTAssertNil(queue.next(), "waits for the missing first command")
        XCTAssertEqual(queue.streamStates.first?.received, 0)
        XCTAssertEqual(queue.streamStates.first?.waiting, 3)
        _ = queue.receive(command("c1", seq: 1), now: start)
        XCTAssertEqual(drain(&queue), ["c1", "c2", "c3", "c4"])
        XCTAssertEqual(queue.streamStates.first.map { [$0.received, $0.done, $0.waiting] }, [4, 4, 0])
        XCTAssertTrue(queue.isIdle)
    }

    func testAnswersReplaysFromMemoryAndIgnoresCopiesStillQueued() {
        var queue = AssistQueue<AssistCommand>()
        _ = queue.receive(command("a", seq: 1), now: start)
        _ = queue.receive(command("b", seq: 2), now: start)
        guard case .ignored = queue.receive(command("b", seq: 2), now: start) else { return XCTFail("copy of a queued command") }
        let first = queue.next()!
        guard case .ignored = queue.receive(command("a", seq: 1), now: start) else { return XCTFail("copy of the running command") }
        queue.finish(first, AssistSession.Result(id: "a", status: "applied", message: nil))
        guard case .answered(let replay) = queue.receive(command("a", seq: 1), now: start) else { return XCTFail("replay") }
        XCTAssertEqual(replay.status, "duplicate")
        XCTAssertEqual(drain(&queue), ["b"])
    }

    func testSkipsCommandsThatDependOnARefusedOne() {
        var queue = AssistQueue<AssistCommand>()
        _ = queue.receive(command("a", seq: 1), now: start)
        _ = queue.receive(command("b", seq: 2, after: ["a"]), now: start)
        _ = queue.receive(command("c", seq: 3, after: ["b"]), now: start)
        _ = queue.receive(command("d", seq: 4), now: start)
        var outcomes: [String: String] = [:]
        while let item = queue.next() {
            let status = item.id == "a" || queue.blocker(of: item) != nil ? "rejected" : "applied"
            outcomes[item.id] = status
            queue.finish(item, AssistSession.Result(id: item.id, status: status, message: nil))
        }
        XCTAssertEqual(outcomes, ["a": "rejected", "b": "rejected", "c": "rejected", "d": "applied"])
    }

    func testGivesUpOnAGapAfterTheTimeoutAndRefusesTheLateCommand() {
        var queue = AssistQueue<AssistCommand>()
        _ = queue.receive(command("c2", seq: 2), now: start)
        queue.releaseGaps(now: start.addingTimeInterval(AssistQueue<AssistCommand>.gapTimeout - 1))
        XCTAssertNil(queue.next())
        queue.releaseGaps(now: start.addingTimeInterval(AssistQueue<AssistCommand>.gapTimeout))
        XCTAssertEqual(drain(&queue), ["c2"])
        guard case .answered(let late) = queue.receive(command("c1", seq: 1), now: start) else { return XCTFail("late command") }
        XCTAssertEqual(late.status, "rejected")
    }

    func testStartsAStreamFromTheSettledBaseAfterARelaunch() {
        var queue = AssistQueue<AssistCommand>()
        _ = queue.receive(command("c7", seq: 7, base: 6), now: start)
        XCTAssertEqual(drain(&queue), ["c7"])
        _ = queue.receive(command("other", seq: 1, stream: "s2"), now: start)
        _ = queue.receive(command("plain", stream: nil), now: start)
        XCTAssertEqual(drain(&queue), ["other", "plain"])
        XCTAssertEqual(Set(queue.streamStates.map(\.id)), ["s1", "s2"])
    }

    func testPacesEachChangeLikeATap() {
        XCTAssertGreaterThan(AssistCommand.Op.setTopping(item: "", topping: .whip, on: true).pace, AssistCommand.Op.setName("").pace)
        XCTAssertEqual(AssistCommand.Op.unsupported("").pace, 0)
    }
}
