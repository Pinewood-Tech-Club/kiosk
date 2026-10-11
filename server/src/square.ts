export type SquareEnvironment = "sandbox" | "production";

const TIMEOUT_MS = 8000;

export class SquareError extends Error {
  constructor(
    readonly status: number,
    readonly codes: string[],
    message: string,
  ) {
    super(message);
  }

  get isAuth(): boolean {
    return this.status === 401 || this.codes.some((c) => c === "UNAUTHORIZED" || c === "ACCESS_TOKEN_EXPIRED" || c === "ACCESS_TOKEN_REVOKED");
  }

  get isTransient(): boolean {
    return this.status === 0 || this.status === 429 || this.status >= 500;
  }
}

export function squareEnvironment(env: Env): SquareEnvironment {
  const configured = (env.SQUARE_ENVIRONMENT ?? "").trim().toLowerCase();
  if (configured === "production" || configured === "sandbox") return configured;
  return (env.SQUARE_APPLICATION_ID ?? "").startsWith("sandbox-") ? "sandbox" : "production";
}

export function squareBaseUrl(environment: SquareEnvironment): string {
  return environment === "sandbox" ? "https://connect.squareupsandbox.com" : "https://connect.squareup.com";
}

export async function squareRequest<T = Record<string, unknown>>(
  environment: SquareEnvironment,
  path: string,
  init: { method?: string; body?: unknown; bearer?: string; authorization?: string; timeoutMs?: number },
): Promise<T> {
  const headers: Record<string, string> = { "Content-Type": "application/json", Accept: "application/json" };
  if (init.bearer) headers.Authorization = `Bearer ${init.bearer}`;
  if (init.authorization) headers.Authorization = init.authorization;
  let response: Response;
  try {
    response = await fetch(`${squareBaseUrl(environment)}${path}`, {
      method: init.method ?? (init.body === undefined ? "GET" : "POST"),
      headers,
      body: init.body === undefined ? undefined : JSON.stringify(init.body),
      signal: AbortSignal.timeout(init.timeoutMs ?? TIMEOUT_MS),
    });
  } catch (error) {
    throw new SquareError(0, [], `Square ${path} unreachable: ${String(error)}`);
  }
  const text = await response.text();
  let body: Record<string, unknown> = {};
  try {
    body = text ? (JSON.parse(text) as Record<string, unknown>) : {};
  } catch {}
  const errors = Array.isArray(body.errors) ? (body.errors as { code?: string; detail?: string; category?: string }[]) : [];
  if (!response.ok || errors.length > 0) {
    const codes = errors.map((e) => e.code ?? "ERROR");
    const detail = errors.map((e) => `${e.code ?? "ERROR"}: ${e.detail ?? ""}`).join("; ");
    const oauthError = typeof body.message === "string" ? body.message : typeof body.error === "string" ? body.error : "";
    throw new SquareError(response.status, codes, `Square ${path} HTTP ${response.status}${detail ? `: ${detail}` : oauthError ? `: ${oauthError}` : ""}`);
  }
  return body as T;
}

export interface SquareLocation {
  id: string;
  name: string;
  businessName: string | null;
  status: string;
  capabilities: string[];
}

export async function listLocations(environment: SquareEnvironment, accessToken: string): Promise<SquareLocation[]> {
  const body = await squareRequest<{ locations?: Record<string, unknown>[] }>(environment, "/v2/locations", { bearer: accessToken });
  return (body.locations ?? []).map((l) => ({
    id: String(l.id),
    name: String(l.name ?? ""),
    businessName: typeof l.business_name === "string" ? l.business_name : null,
    status: String(l.status ?? ""),
    capabilities: Array.isArray(l.capabilities) ? (l.capabilities as string[]) : [],
  }));
}

/** The configured location if the merchant has it, else the first active location that takes cards. */
export function pickLocation(locations: SquareLocation[], preferred: string | undefined): SquareLocation | null {
  const wanted = preferred?.trim();
  if (wanted) return locations.find((l) => l.id === wanted) ?? null;
  return (
    locations.find((l) => l.status === "ACTIVE" && l.capabilities.includes("CREDIT_CARD_PROCESSING")) ??
    locations.find((l) => l.status === "ACTIVE") ??
    null
  );
}
