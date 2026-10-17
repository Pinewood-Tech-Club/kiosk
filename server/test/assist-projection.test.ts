import { describe, expect, it } from "vitest";
import { ITEM, type PjCommand, type PjSession, context, loadProjection } from "./assist-projection";

const pj = loadProjection();

const builder = (overrides: Partial<PjSession> = {}): PjSession => ({
  screen: "builder",
  step: "vessel",
  editing: false,
  items: [{ id: ITEM(1), vessel: "cup", flavors: [], toppings: [], cents: 0, current: true, inOrder: false }],
  customerName: "",
  totalCents: 0,
  paying: false,
  orderingOpen: true,
  maxScoops: 3,
  results: [],
  ...overrides,
});

let n = 0;
const cmd = (op: string, fields: Partial<PjCommand> = {}): PjCommand => ({ id: `c-${++n}`, op, ...fields });
const shape = (items: { vessel: string; flavors: string[]; toppings: string[]; cents: number; inOrder: boolean; current: boolean }[]) =>
  items.map((i) => [i.vessel, i.flavors.join("+"), i.toppings.join("+"), i.cents, i.inOrder, i.current]);

describe("assist projection", () => {
  it("keeps the kiosk's donation in the total while the order has items", () => {
    const session = builder({
      screen: "summary",
      step: null,
      items: [{ id: ITEM(1), vessel: "cup", flavors: ["vanilla"], toppings: [], cents: 400, current: false, inOrder: true }],
      totalCents: 900,
      donationCents: 500,
    });
    const topped = pj.pjProject(session, [cmd("setTopping", { item: ITEM(1), topping: "whip", on: true })], context()).view;
    expect([topped.totalCents, topped.donationCents]).toEqual([950, 500]);
    const emptied = pj.pjProject(session, [cmd("removeItem", { item: ITEM(1) })], context()).view;
    expect([emptied.totalCents, emptied.donationCents]).toEqual([0, 0]);
  });

  it("prices each item on its own: $4, $7, $9 for 1 to 3 scoops, +$1.50 a cone, +$0.50 a topping", () => {
    const price = (vessel: string, scoops: number, toppings: number) =>
      pj.pjPrice({ vessel, flavors: Array(scoops).fill("vanilla"), toppings: Array(toppings).fill("whip") });
    expect([0, 1, 2, 3].map((s) => price("cup", s, 0))).toEqual([0, 400, 700, 900]);
    expect(price("cone", 1, 0)).toBe(550);
    expect(price("cone", 3, 2)).toBe(1150);
    expect(price("cup", 2, 1)).toBe(750);
  });

  it("applies a rapid series of taps the way the kiosk would, with live prices and totals", () => {
    const ctx = context();
    const ref = ITEM(9);
    const commands = [
      cmd("setVessel", { item: ITEM(1), vessel: "cone" }),
      cmd("addScoop", { item: ITEM(1), flavor: "vanilla" }),
      cmd("addScoop", { item: ITEM(1), flavor: "chocolate" }),
      cmd("setTopping", { item: ITEM(1), topping: "whip", on: true }),
      cmd("addItem", { ref }),
      cmd("addScoop", { item: ref, flavor: "cookies" }),
      cmd("setTopping", { item: ref, topping: "sprinkles", on: true }),
    ];
    const { view, failed } = pj.pjProject(builder(), commands, ctx);
    expect(failed).toEqual([]);
    expect(view.screen).toBe("builder");
    expect(view.step).toBe("toppings");
    expect(shape(view.items)).toEqual([
      ["cone", "vanilla+chocolate", "whip", 900, true, false],
      ["cup", "cookies", "sprinkles", 450, true, true],
    ]);
    expect(view.items[1].id).toBe(ref);
    expect(view.totalCents).toBe(1350);

    const summary = pj.pjProject(builder(), [...commands, cmd("navigate", { to: "summary", ref: ITEM(10) })], ctx).view;
    expect(summary.screen).toBe("summary");
    expect(summary.items.every((i) => i.inOrder && !i.current)).toBe(true);
    const named = pj.pjProject(builder(), [...commands, cmd("navigate", { to: "name" }), cmd("setName", { name: "  Alexandria Ocasio  " })], ctx).view;
    expect(named.screen).toBe("name");
    expect(named.customerName).toBe("Alexandria Ocasio");
  });

  it("refuses what the kiosk refuses: a 4th scoop, sold-out supplies, toppings before a scoop, payment, missing items", () => {
    const ctx = context(["flavor:chocolate", "vessel:cone", "topping:mms"]);
    const tooMany = pj.pjProject(builder(), [1, 2, 3, 4].map(() => cmd("addScoop", { item: ITEM(1), flavor: "vanilla" })), ctx);
    expect(tooMany.failed.map((f) => f.why)).toEqual(["3 scoops max"]);
    expect(tooMany.view.items[0].flavors).toHaveLength(3);

    const refused = (c: PjCommand, session = builder()) => pj.pjProject(session, [c], ctx).failed[0]?.why ?? null;
    expect(refused(cmd("addScoop", { item: ITEM(1), flavor: "chocolate" }))).toBe("Chocolate is sold out");
    expect(refused(cmd("setVessel", { item: ITEM(1), vessel: "cone" }))).toBe("Waffle cones are sold out");
    expect(refused(cmd("setTopping", { item: ITEM(1), topping: "whip", on: true }))).toBe("Add a scoop first");
    expect(refused(cmd("addScoop", { item: ITEM(5), flavor: "vanilla" }))).toBe("That item is no longer in the order");
    expect(refused(cmd("navigate", { to: "summary" }))).toBe("The order is empty");
    expect(refused(cmd("addScoop", { item: ITEM(1), flavor: "vanilla" }), builder({ paying: true }))).toBe("Payment is in progress on the kiosk");
    expect(refused(cmd("navigate", { to: "builder" }), builder({ screen: "attract", items: [], orderingOpen: false }))).toBe("This kiosk is closed");

    const withMms = builder({ items: [{ id: ITEM(1), vessel: "cup", flavors: ["vanilla"], toppings: ["mms"], cents: 450, current: true, inOrder: true }] });
    expect(refused(cmd("setTopping", { item: ITEM(1), topping: "mms", on: true }), withMms)).toBe("M&M's is sold out");
    expect(refused(cmd("setTopping", { item: ITEM(1), topping: "mms", on: false }), withMms)).toBeNull();
  });

  it("takes another item back out of the tray to edit it, adding the one being built to the order first", () => {
    const session = builder({
      step: "flavors",
      items: [
        { id: ITEM(1), vessel: "cone", flavors: ["vanilla"], toppings: [], cents: 550, current: false, inOrder: true },
        { id: ITEM(2), vessel: "cup", flavors: ["cookies"], toppings: [], cents: 400, current: true, inOrder: true },
      ],
      totalCents: 950,
    });
    const view = pj.pjProject(session, [cmd("setTopping", { item: ITEM(1), topping: "whip", on: true })], context()).view;
    expect(view.editing).toBe(true);
    expect(view.step).toBe("toppings");
    expect(view.items.map((i) => [i.id, i.current, i.toppings.join()])).toEqual([
      [ITEM(1), true, "whip"],
      [ITEM(2), false, ""],
    ]);
    expect(view.totalCents).toBe(1000);

    const fromSummary = pj.pjProject({ ...session, screen: "summary", step: null }, [cmd("addScoop", { item: ITEM(2), flavor: "vanilla" })], context()).view;
    expect(fromSummary.screen).toBe("builder");
    expect(fromSummary.items.find((i) => i.current)?.flavors).toEqual(["cookies", "vanilla"]);
  });

  it("names the item being built after the staff page's id while it has no scoops or toppings", () => {
    const ref = ITEM(42);
    const fromAttract = pj.pjProject(builder({ screen: "attract", items: [] }), [cmd("navigate", { to: "builder", ref })], context()).view;
    expect(fromAttract.items.map((i) => [i.id, i.inOrder])).toEqual([[ref, false]]);
    const coneOnly = builder({ items: [{ id: ITEM(1), vessel: "cone", flavors: [], toppings: [], cents: 150, current: true, inOrder: true }] });
    const renamed = pj.pjProject(coneOnly, [cmd("addItem", { ref })], context()).view;
    expect(renamed.items.map((i) => [i.id, i.vessel, i.inOrder])).toEqual([[ref, "cone", true]]);
    const scooped = builder({ items: [{ id: ITEM(1), vessel: "cup", flavors: [], toppings: ["whip"], cents: 50, current: true, inOrder: true }] });
    expect(pj.pjProject(scooped, [cmd("addItem", { ref })], context()).view.items.map((i) => i.id)).toEqual([ITEM(1)]);
  });

  it("chains a command to the last pending one on the same item and keeps the settled base", () => {
    const ref = ITEM(7);
    const a = cmd("addScoop", { item: ITEM(1), flavor: "vanilla", seq: 4 });
    const b = cmd("addItem", { ref, seq: 5 });
    const c = cmd("navigate", { to: "summary", seq: 6 });
    expect(pj.pjAfter([a, b, c], cmd("setTopping", { item: ITEM(1) }))).toEqual([a.id]);
    expect(pj.pjAfter([a, b, c], cmd("addScoop", { item: ref }))).toEqual([b.id]);
    expect(pj.pjAfter([a, b, c], cmd("startOver"))).toEqual([]);
    expect(pj.pjBase([a, b, c], 6)).toBe(3);
    expect(pj.pjBase([], 6)).toBe(6);
  });

  it("drops a rejected command and everything that depends on it, and settles what the kiosk has done", () => {
    const a = cmd("addScoop", { item: ITEM(1), flavor: "chocolate", seq: 1 });
    const b = cmd("setTopping", { item: ITEM(1), topping: "whip", on: true, seq: 2, after: [a.id] });
    const c = cmd("addScoop", { item: ITEM(2), flavor: "vanilla", seq: 3 });
    const d = cmd("setTopping", { item: ITEM(1), topping: "mms", on: true, seq: 4, after: [b.id] });
    const e = cmd("navigate", { to: "summary", seq: 5 });
    const r = pj.pjReconcile([a, b, c, d, e], { results: [{ id: a.id, status: "rejected", message: "Chocolate is sold out" }], streams: [{ id: "s", received: 5, done: 1 }] }, "s");
    expect(r.rejected).toEqual({ command: a, why: "Chocolate is sold out" });
    expect(r.skipped).toBe(2);
    expect(r.pending.map((x) => x.id)).toEqual([c.id, e.id]);
    expect(r.received).toBe(5);

    const later = pj.pjReconcile(r.pending, { results: [{ id: c.id, status: "applied" }], streams: [{ id: "s", received: 5, done: 5 }] }, "s");
    expect(later.pending).toEqual([]);
    expect(later.rejected).toBeNull();
    expect(pj.pjReconcile([c, e], { results: [], streams: [{ id: "other", received: 9, done: 9 }] }, "s").pending).toHaveLength(2);
  });
});
