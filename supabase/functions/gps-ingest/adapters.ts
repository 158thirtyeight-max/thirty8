// One entry per supported tracking provider. Intentionally EMPTY until a GPS device/provider is
// selected: the provider's real protocol and credentials decide the adapter, so none is invented here.
//
// Example shape of a future adapter:
//
//   acme: {
//     secretKey: "gps_acme_webhook_secret",                 // row in private.app_secrets
//     authenticate: async (req, secret) => req.headers.get("x-acme-signature") === await hmac(secret, await req.text()),
//     parse: async (req) => (await req.json()).points.map((p) => ({
//       deviceIdentifier: p.imei, latitude: p.lat, longitude: p.lon, recordedAt: p.ts, speedKmh: p.speed,
//     })),
//   },

export interface Fix {
  deviceIdentifier: string;
  latitude: number;
  longitude: number;
  recordedAt: string; // ISO-8601
  accuracyM?: number;
  speedKmh?: number;
  heading?: number;
}

export interface ProviderAdapter {
  /** Name of the secret in private.app_secrets used to authenticate the provider's calls. */
  secretKey: string;
  /** Must verify the request BEFORE it is parsed. Receives a clone so the body can be read. */
  authenticate(req: Request, secret: string): Promise<boolean>;
  /** Provider payload -> normalized fixes. */
  parse(req: Request): Promise<Fix[]>;
}

export const ADAPTERS: Record<string, ProviderAdapter> = {};
