export type StaffSection = "make" | "handoff" | "supplies" | "open" | "kiosk" | "feed" | "stats" | "board";

export interface StaffRole {
  title: string;
  summary: string;
  icon: string;
  kind: "ipad" | "display";
  alerts: "front" | "quiet" | "display" | "none";
  columns: StaffSection[][];
}

export const STAFF_ROLES = {
  scooper: {
    title: "Scooper",
    summary: "Make list, oldest first, with start and done buttons, sold-out supplies and opening or closing the kiosk.",
    icon: "cone",
    kind: "ipad",
    alerts: "quiet",
    columns: [["make"], ["open"], ["supplies"]],
  },
  toppings: {
    title: "Toppings",
    summary: "Help alerts, toppings per order, handing orders off, cancelling, kiosk health and supplies.",
    icon: "sparkles",
    kind: "ipad",
    alerts: "front",
    columns: [["handoff"], ["open", "kiosk"], ["supplies"]],
  },
  organizer: {
    title: "Organizer display",
    summary: "Read-only laptop display: sales stats, the order feed, kiosk health and alerts.",
    icon: "chart",
    kind: "display",
    alerts: "display",
    columns: [["stats"], ["feed"], ["open", "kiosk", "supplies"]],
  },
  board: {
    title: "Order board",
    summary: "Read-only display of orders being made and ready for pickup, readable across the booth.",
    icon: "list",
    kind: "display",
    alerts: "none",
    columns: [["board"]],
  },
} satisfies Record<string, StaffRole>;

export type StaffRoleId = keyof typeof STAFF_ROLES;

export function staffRole(id: string): StaffRole | null {
  return Object.hasOwn(STAFF_ROLES, id) ? STAFF_ROLES[id as StaffRoleId] : null;
}
