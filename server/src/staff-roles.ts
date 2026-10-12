import type { SupplyKind } from "./schema";

export type StaffSection = "make" | "handoff" | "supplies" | "kiosks" | "feed" | "stats" | "board";

export interface StaffRole {
  title: string;
  summary: string;
  icon: string;
  kind: "ipad" | "display";
  alerts: "front" | "quiet" | "display" | "none";
  owns: SupplyKind[];
  columns: StaffSection[][];
}

export const STAFF_ROLES = {
  scooper: {
    title: "Scooper",
    summary: "Make list, oldest first, with start and done buttons, sold-out flavors, cups and cones, and the kiosks.",
    icon: "cone",
    kind: "ipad",
    alerts: "quiet",
    owns: ["flavor", "vessel"],
    columns: [["make"], ["kiosks"], ["supplies"]],
  },
  toppings: {
    title: "Toppings",
    summary: "Help alerts, toppings per order, handing orders off, cancelling, sold-out toppings and the kiosks.",
    icon: "sparkles",
    kind: "ipad",
    alerts: "front",
    owns: ["topping"],
    columns: [["handoff"], ["kiosks"], ["supplies"]],
  },
  organizer: {
    title: "Organizer display",
    summary: "Read-only laptop display: sales stats, the order feed, each kiosk's status and alerts.",
    icon: "chart",
    kind: "display",
    alerts: "display",
    owns: [],
    columns: [["stats"], ["feed"], ["kiosks", "supplies"]],
  },
  board: {
    title: "Order board",
    summary: "Read-only display of orders being made and ready for pickup, readable across the booth.",
    icon: "list",
    kind: "display",
    alerts: "none",
    owns: [],
    columns: [["board"]],
  },
} satisfies Record<string, StaffRole>;

export type StaffRoleId = keyof typeof STAFF_ROLES;

export function staffRole(id: string): StaffRole | null {
  return Object.hasOwn(STAFF_ROLES, id) ? STAFF_ROLES[id as StaffRoleId] : null;
}
