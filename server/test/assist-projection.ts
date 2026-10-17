import { ASSIST_PROJECTION_EXPORTS, ASSIST_PROJECTION_JS } from "../src/assist-projection";

export interface PjItem { id: string; vessel: string; flavors: string[]; toppings: string[]; cents: number; current: boolean; inOrder: boolean }
export interface PjView {
  screen: string;
  step: string | null;
  editing: boolean;
  items: PjItem[];
  customerName: string;
  totalCents: number;
  paying: boolean;
  orderingOpen: boolean;
  maxScoops: number;
}
export interface PjCommand {
  id: string;
  op: string;
  item?: string;
  flavor?: string;
  vessel?: string;
  topping?: string;
  on?: boolean;
  name?: string;
  to?: string;
  ref?: string;
  stream?: string;
  seq?: number;
  base?: number;
  after?: string[];
  [key: string]: unknown;
}
export interface PjContext { soldOut(kind: string, id: string): boolean; title(kind: string, id: string): string }
export interface PjSession extends Partial<PjView> {
  results?: { id: string; status: string; message?: string }[];
  streams?: { id: string; received: number; done: number; waiting?: number }[];
  [key: string]: unknown;
}
export interface Projection {
  pjPrice(item: { vessel: string; flavors: string[]; toppings: string[] }): number;
  pjModel(session: PjSession | null, ctx: PjContext): unknown;
  pjApply(model: unknown, command: PjCommand): string | null;
  pjView(model: unknown): PjView;
  pjProject(session: PjSession | null, commands: PjCommand[], ctx: PjContext): { view: PjView; failed: { id: string; why: string }[] };
  pjAfter(pending: PjCommand[], command: PjCommand): string[];
  pjBase(pending: PjCommand[], seq: number): number;
  pjReconcile(
    pending: PjCommand[],
    session: PjSession | null,
    stream: string | null,
  ): { pending: PjCommand[]; rejected: { command: PjCommand; why: string } | null; skipped: number; received: number | null };
}

export function loadProjection(): Projection {
  return new Function(`${ASSIST_PROJECTION_JS}\nreturn {${ASSIST_PROJECTION_EXPORTS.join(",")}};`)() as Projection;
}

const TITLES: Record<string, string> = {
  vanilla: "Vanilla",
  chocolate: "Chocolate",
  cookies: "Cookies & Cream",
  whip: "Whipped Cream",
  fudge: "Hot Fudge",
  sprinkles: "Sprinkles",
  gummies: "Gummy Bears",
  mms: "M&M's",
  caramel: "Caramel Syrup",
};

export function context(out: string[] = []): PjContext & { out: Set<string> } {
  const set = new Set(out);
  return { out: set, soldOut: (kind, id) => set.has(`${kind}:${id}`), title: (_kind, id) => TITLES[id] ?? id };
}

export const ITEM = (n: number) => `00000000-0000-4000-8000-${String(n).padStart(12, "0")}`;
