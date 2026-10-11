export type StaffSection = "queue" | "feed" | "soldout" | "kiosk" | "stats";

export interface StaffRole {
  title: string;
  summary: string;
  icon: string;
  alerts: boolean;
  columns: StaffSection[][];
}

export const STAFF_ROLES = {
  counter: {
    title: "Counter",
    summary: "Toppings station iPad: alerts, the order queue, sold-out toggles and kiosk health.",
    icon: "cone",
    alerts: true,
    columns: [["queue"], ["soldout", "kiosk"]],
  },
  organizer: {
    title: "Organizer",
    summary: "Laptop at the back: sales stats, the full order feed, alerts, kiosk health and sold-out.",
    icon: "chart",
    alerts: true,
    columns: [["stats"], ["feed"], ["kiosk", "soldout"]],
  },
} satisfies Record<string, StaffRole>;

export type StaffRoleId = keyof typeof STAFF_ROLES;

export function staffRole(id: string): StaffRole | null {
  return Object.hasOwn(STAFF_ROLES, id) ? STAFF_ROLES[id as StaffRoleId] : null;
}
