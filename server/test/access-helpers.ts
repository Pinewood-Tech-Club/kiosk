import { env } from "cloudflare:workers";
import { accessTesting, type AccessJwk } from "../src/access";
import { base64url } from "../src/http";

export const OWNER = "owner@test.example";
export const SECOND = "second@test.example";

export interface TestKey {
  kid: string;
  privateKey: CryptoKey;
  jwk: AccessJwk;
}

export async function newKey(kid: string): Promise<TestKey> {
  const pair = (await crypto.subtle.generateKey({ name: "RSASSA-PKCS1-v1_5", modulusLength: 2048, publicExponent: new Uint8Array([1, 0, 1]), hash: "SHA-256" }, true, ["sign", "verify"])) as CryptoKeyPair;
  const exported = (await crypto.subtle.exportKey("jwk", pair.publicKey)) as JsonWebKey;
  return { kid, privateKey: pair.privateKey, jwk: { kty: "RSA", alg: "RS256", use: "sig", n: exported.n, e: exported.e, kid } };
}

const encode = (value: unknown) => base64url(new TextEncoder().encode(JSON.stringify(value)));

export interface TokenOptions {
  claims?: Record<string, unknown>;
  header?: Record<string, unknown>;
  email?: string | null;
}

export async function signToken(key: TestKey, options: TokenOptions = {}): Promise<string> {
  const now = Math.floor(Date.now() / 1000);
  const claims: Record<string, unknown> = {
    aud: [env.ACCESS_AUD],
    iss: env.ACCESS_TEAM_DOMAIN,
    iat: now,
    nbf: now - 5,
    exp: now + 3600,
    type: "app",
    ...options.claims,
  };
  if (options.email !== null) claims.email = options.email ?? OWNER;
  const head = encode({ alg: "RS256", kid: key.kid, typ: "JWT", ...options.header });
  const body = encode(claims);
  const signature = await crypto.subtle.sign("RSASSA-PKCS1-v1_5", key.privateKey, new TextEncoder().encode(`${head}.${body}`));
  return `${head}.${body}.${base64url(signature)}`;
}

export function serveKeys(...keys: TestKey[]) {
  const calls = { count: 0 };
  accessTesting.useFetcher(async () => {
    calls.count++;
    return keys.map((k) => k.jwk);
  }, { refetchIntervalMs: 0 });
  return calls;
}
