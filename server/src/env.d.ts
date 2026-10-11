interface OptionalSecrets {
  SQUARE_APPLICATION_ID?: string;
  SQUARE_APPLICATION_SECRET?: string;
  SQUARE_ACCESS_TOKEN?: string;
  STAFF_PIN?: string;
}

interface Env extends OptionalSecrets {}

declare namespace Cloudflare {
  interface Env extends OptionalSecrets {}
}
