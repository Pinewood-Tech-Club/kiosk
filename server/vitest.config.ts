import { cloudflareTest, readD1Migrations } from "@cloudflare/vitest-plugin";
import { defineConfig } from "vitest/config";

const secrets = {
  BOOTH_TOKEN: "test-kiosk-token",
  STAFF_TOKEN: "test-staff-token",
  STAFF_PIN: "2468",
  SQUARE_APPLICATION_ID: "sq0idp-test-app",
  SQUARE_APPLICATION_SECRET: "sq0csp-test-secret",
};
const accessVars = {
  ACCESS_TEAM_DOMAIN: "https://test-team.cloudflareaccess.com",
  ACCESS_AUD: "test-aud-tag",
  ADMIN_EMAILS: "Owner@Test.example, second@test.example",
};
Object.assign(process.env, secrets);

export default defineConfig(async () => {
  const migrations = await readD1Migrations("./migrations");
  return {
    plugins: [
      cloudflareTest({
        wrangler: { configPath: "./wrangler.jsonc" },
        miniflare: {
          bindings: { ...secrets, ...accessVars, TEST_MIGRATIONS: migrations },
        },
      }),
    ],
    test: {
      setupFiles: ["./test/apply-migrations.ts"],
    },
  };
});
