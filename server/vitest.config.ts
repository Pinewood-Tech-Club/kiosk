import { cloudflareTest, readD1Migrations } from "@cloudflare/vitest-plugin";
import { defineConfig } from "vitest/config";

const secrets = {
  BOOTH_TOKEN: "test-kiosk-token",
  STAFF_TOKEN: "test-staff-token",
  STAFF_PIN: "2468",
  SQUARE_APPLICATION_ID: "sq0idp-test-app",
  SQUARE_APPLICATION_SECRET: "sq0csp-test-secret",
};
Object.assign(process.env, secrets);

export default defineConfig(async () => {
  const migrations = await readD1Migrations("./migrations");
  return {
    plugins: [
      cloudflareTest({
        wrangler: { configPath: "./wrangler.jsonc" },
        miniflare: {
          bindings: { ...secrets, TEST_MIGRATIONS: migrations },
        },
      }),
    ],
    test: {
      setupFiles: ["./test/apply-migrations.ts"],
    },
  };
});
