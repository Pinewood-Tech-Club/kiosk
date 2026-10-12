// Starts the one-time Square OAuth connection and opens Square's authorize page.
//   set -a; . ~/.config/techclub-icecream/secrets.env; set +a
//   node scripts/square-connect.mjs                 # production (STAFF_TOKEN)
//   BOOTH_URL=https://kiosk-staging.jamboree.techclub.pw STAFF_TOKEN=$STAGING_STAFF_TOKEN node scripts/square-connect.mjs
//   node scripts/square-connect.mjs status | refresh | revoke
import { execFile } from "node:child_process";

const base = (process.env.BOOTH_URL ?? "https://kiosk.jamboree.techclub.pw").replace(/\/$/, "");
const token = process.env.STAFF_TOKEN;
const command = process.argv[2] ?? "connect";
if (!token) {
  console.error("Set STAFF_TOKEN");
  process.exit(2);
}

async function call(path, method = "GET") {
  const response = await fetch(base + path, { method, headers: { Authorization: `Bearer ${token}`, "X-Booth-Device": "square-connect-cli" } });
  const body = await response.json().catch(() => null);
  if (!response.ok) {
    console.error(`HTTP ${response.status}`, JSON.stringify(body?.error ?? body));
    process.exit(1);
  }
  return body;
}

if (command === "status") console.log(JSON.stringify(await call("/v1/square/status?verify=1"), null, 2));
else if (command === "refresh") console.log(JSON.stringify(await call("/v1/square/refresh", "POST"), null, 2));
else if (command === "revoke") console.log(JSON.stringify(await call("/v1/square/revoke", "POST"), null, 2));
else {
  const started = await call("/v1/square/oauth/start", "POST");
  console.log(`Environment: ${started.environment}`);
  console.log(`Redirect URL to register in the Developer Console (OAuth page): ${started.redirectUrl}`);
  console.log(`Authorize within 10 minutes:\n${started.url}`);
  execFile("open", [started.url], () => {});
}
