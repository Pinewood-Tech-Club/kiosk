export const MAX_SCOOPS_PER_ITEM = 3;
export const WAFFLE_CONE_CENTS = 150;
export const TOPPING_CENTS = 50;

export const VESSEL_TITLES: Record<string, string> = { cup: "Cup", cone: "Waffle Cone" };
export const FLAVOR_TITLES: Record<string, string> = { vanilla: "Vanilla", chocolate: "Chocolate", cookies: "Cookies & Cream" };
export const TOPPING_TITLES: Record<string, string> = {
  whip: "Whipped Cream",
  fudge: "Hot Fudge",
  chocolate: "Chocolate Syrup",
  caramel: "Caramel Syrup",
  gummies: "Gummy Bears",
  mms: "M&M's",
  sprinkles: "Sprinkles",
};

export interface CartItem {
  vessel: "cup" | "cone";
  flavors: string[];
  toppings: string[];
}

export interface QuoteLine {
  item: CartItem;
  scoopShareCents: number;
  vesselCents: number;
  toppingCents: number;
  totalCents: number;
}

export interface Quote {
  lines: QuoteLine[];
  scoopCount: number;
  totalCents: number;
}

export interface CatalogEntry {
  variationId: string;
  itemName: string;
  cents: number;
}

export interface Catalog {
  categoryName: string;
  firstScoop: CatalogEntry;
  secondScoop: CatalogEntry;
  additionalScoop: CatalogEntry;
  waffleCone: CatalogEntry;
  topping: CatalogEntry;
}

export interface ReceiptLine {
  title: string;
  detail: string;
  quantity: number;
  baseCents: number;
  cents: number;
}

function humanize(id: string): string {
  return id.replace(/[_-]+/g, " ").replace(/\b\w/g, (c) => c.toUpperCase());
}

export const vesselTitle = (id: string) => VESSEL_TITLES[id] ?? humanize(id);
export const flavorTitle = (id: string) => FLAVOR_TITLES[id] ?? humanize(id);
export const toppingTitle = (id: string) => TOPPING_TITLES[id] ?? humanize(id);

/** Each cup or cone is priced on its own: its 1st scoop is $4, the 2nd $3, the 3rd $2. */
export function scoopCents(position: number): number {
  if (position <= 0) return 0;
  if (position === 1) return 400;
  if (position === 2) return 300;
  return 200;
}

export function scoopsTotal(count: number): number {
  let total = 0;
  for (let p = 1; p <= count; p++) total += scoopCents(p);
  return total;
}

export function quote(items: CartItem[]): Quote {
  let scoopCount = 0;
  const lines = items.map((item) => {
    const scoopShareCents = scoopsTotal(item.flavors.length);
    scoopCount += item.flavors.length;
    const vesselCents = item.vessel === "cone" ? WAFFLE_CONE_CENTS : 0;
    const toppingCents = item.toppings.length * TOPPING_CENTS;
    return { item, scoopShareCents, vesselCents, toppingCents, totalCents: scoopShareCents + vesselCents + toppingCents };
  });
  return { lines, scoopCount, totalCents: lines.reduce((sum, l) => sum + l.totalCents, 0) };
}

export function catalogScoopEntry(catalog: Catalog, position: number): CatalogEntry {
  if (position === 1) return catalog.firstScoop;
  if (position === 2) return catalog.secondScoop;
  return catalog.additionalScoop;
}

/** Null when the catalog reproduces the kiosk's prices, otherwise what differs. */
export function pricingMismatch(catalog: Catalog): string | null {
  let catalogTotal = 0;
  for (let count = 1; count <= MAX_SCOOPS_PER_ITEM * 4; count++) {
    catalogTotal += catalogScoopEntry(catalog, count).cents;
    if (catalogTotal !== scoopsTotal(count)) return `${count} scoops: catalog ${catalogTotal} vs kiosk ${scoopsTotal(count)} cents`;
  }
  if (catalog.waffleCone.cents !== WAFFLE_CONE_CENTS) return `Waffle Cone: catalog ${catalog.waffleCone.cents} vs kiosk ${WAFFLE_CONE_CENTS} cents`;
  if (catalog.topping.cents !== TOPPING_CENTS) return `Topping: catalog ${catalog.topping.cents} vs kiosk ${TOPPING_CENTS} cents`;
  return null;
}

type SquareLineItem = Record<string, unknown>;

const money = (cents: number) => ({ amount: cents, currency: "USD" });

/** One line per scoop priced by its position in its item, one per waffle cone and one per topping, as the app builds them. */
export function catalogLineItems(q: Quote, catalog: Catalog): SquareLineItem[] {
  const lines: SquareLineItem[] = [];
  q.lines.forEach((line, index) => {
    const label = `#${index + 1} ${vesselTitle(line.item.vessel)}`;
    for (const [scoop, flavor] of line.item.flavors.entries()) {
      const position = scoop + 1;
      lines.push({ catalog_object_id: catalogScoopEntry(catalog, position).variationId, quantity: "1", note: `${label}: ${flavorTitle(flavor)}` });
    }
    if (line.item.vessel === "cone") {
      lines.push({ catalog_object_id: catalog.waffleCone.variationId, quantity: "1", note: `#${index + 1}` });
    }
    for (const topping of line.item.toppings) {
      lines.push({ catalog_object_id: catalog.topping.variationId, quantity: "1", note: `${label}: ${toppingTitle(topping)}` });
    }
  });
  return lines;
}

export const DONATION_LINE_NAME = "Donation";

/** Custom-amount line, kept out of every catalog tax: auto-applied taxes otherwise reach custom amounts too. */
export function donationLineItem(cents: number, blockedTaxIds: string[]): SquareLineItem {
  return {
    name: DONATION_LINE_NAME,
    quantity: "1",
    base_price_money: money(cents),
    ...(blockedTaxIds.length
      ? { pricing_blocklists: { blocked_taxes: blockedTaxIds.map((id, i) => ({ uid: `donation-tax-${i}`, tax_catalog_object_id: id })) } }
      : {}),
  };
}

export function isDonationLine(line: { title: string; detail: string }): boolean {
  return line.title === DONATION_LINE_NAME && !/^#\d/.test(line.detail);
}

export function adHocLineItems(q: Quote): SquareLineItem[] {
  return q.lines.map((line) => {
    const item = line.item;
    const modifiers: Record<string, unknown>[] = [{ name: item.vessel === "cone" ? "Waffle cone" : "Cup", base_price_money: money(line.vesselCents) }];
    const counts = new Map<string, number>();
    for (const flavor of item.flavors) counts.set(flavor, (counts.get(flavor) ?? 0) + 1);
    for (const [flavor, count] of counts) modifiers.push({ name: flavorTitle(flavor), quantity: String(count), base_price_money: money(0) });
    for (const topping of item.toppings) modifiers.push({ name: toppingTitle(topping), base_price_money: money(TOPPING_CENTS) });
    const scoops = item.flavors.length;
    return {
      name: `Ice cream, ${scoops} scoop${scoops === 1 ? "" : "s"}`,
      quantity: "1",
      base_price_money: money(line.scoopShareCents),
      modifiers,
    };
  });
}

export function chargedLines(q: Quote): ReceiptLine[] {
  const lines: ReceiptLine[] = [];
  const scoopName = (p: number) => (p === 1 ? "Ice Cream (First Scoop)" : p === 2 ? "Ice Cream (Second Scoop)" : "Ice Cream (Third Scoop)");
  q.lines.forEach((line, index) => {
    const label = `#${index + 1} ${vesselTitle(line.item.vessel)}`;
    for (const [scoop, flavor] of line.item.flavors.entries()) {
      const position = scoop + 1;
      const cents = scoopCents(position);
      lines.push({ title: scoopName(position), detail: `${label}: ${flavorTitle(flavor)}`, quantity: 1, baseCents: cents, cents });
    }
    if (line.item.vessel === "cone") {
      lines.push({ title: "Waffle Cone", detail: `#${index + 1}`, quantity: 1, baseCents: WAFFLE_CONE_CENTS, cents: WAFFLE_CONE_CENTS });
    }
    for (const topping of line.item.toppings) {
      lines.push({ title: "Ice Cream Toppings", detail: `${label}: ${toppingTitle(topping)}`, quantity: 1, baseCents: TOPPING_CENTS, cents: TOPPING_CENTS });
    }
  });
  return lines;
}
