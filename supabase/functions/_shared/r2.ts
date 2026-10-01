// Cloudflare R2 (S3-compatible) helpers: presigned PUT URLs via AWS SigV4.
// Credentials live in private.app_secrets, read through get_app_secret:
//   r2_account_id, r2_access_key_id, r2_secret_access_key, r2_bucket,
//   r2_public_base_url  (e.g. https://pub-xxxx.r2.dev or a custom domain)
import { serviceRoleClient } from "./supabase.ts";

export interface R2Config {
  accountId: string;
  accessKeyId: string;
  secretAccessKey: string;
  bucket: string;
  publicBaseUrl: string;
}

export async function getR2Config(): Promise<R2Config> {
  const admin = serviceRoleClient();
  const keys = ["r2_account_id", "r2_access_key_id", "r2_secret_access_key", "r2_bucket", "r2_public_base_url"];
  const values = await Promise.all(keys.map((k) => admin.rpc("get_app_secret", { p_key: k })));
  const [accountId, accessKeyId, secretAccessKey, bucket, publicBaseUrl] = values.map((v) => v.data as string | null);
  if (!accountId || !accessKeyId || !secretAccessKey || !bucket || !publicBaseUrl) {
    throw new Error("R2 is not configured (missing r2_* keys in private.app_secrets)");
  }
  return { accountId, accessKeyId, secretAccessKey, bucket, publicBaseUrl: publicBaseUrl.replace(/\/+$/, "") };
}

const enc = new TextEncoder();

async function hmac(key: ArrayBuffer | Uint8Array, msg: string): Promise<ArrayBuffer> {
  const k = await crypto.subtle.importKey("raw", key, { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  return crypto.subtle.sign("HMAC", k, enc.encode(msg));
}

const hex = (buf: ArrayBuffer) => Array.from(new Uint8Array(buf)).map((b) => b.toString(16).padStart(2, "0")).join("");

async function sha256Hex(s: string): Promise<string> {
  return hex(await crypto.subtle.digest("SHA-256", enc.encode(s)));
}

// RFC 3986 encoding, as SigV4 requires.
const encode = (s: string) => encodeURIComponent(s).replace(/[!'()*]/g, (c) => "%" + c.charCodeAt(0).toString(16).toUpperCase());

/** Presigned PUT URL for `key`; the uploader must send the same Content-Type. */
export async function presignPut(cfg: R2Config, key: string, contentType: string, expiresSeconds = 600): Promise<string> {
  const host = `${cfg.accountId}.r2.cloudflarestorage.com`;
  const region = "auto";
  const now = new Date();
  const amzDate = now.toISOString().replace(/[:-]|\.\d{3}/g, "");
  const date = amzDate.slice(0, 8);
  const scope = `${date}/${region}/s3/aws4_request`;
  const path = `/${cfg.bucket}/${key.split("/").map(encode).join("/")}`;

  const query: Record<string, string> = {
    "X-Amz-Algorithm": "AWS4-HMAC-SHA256",
    "X-Amz-Credential": `${cfg.accessKeyId}/${scope}`,
    "X-Amz-Date": amzDate,
    "X-Amz-Expires": String(expiresSeconds),
    "X-Amz-SignedHeaders": "content-type;host",
  };
  const canonicalQuery = Object.keys(query).sort().map((k) => `${encode(k)}=${encode(query[k])}`).join("&");
  const canonicalRequest = [
    "PUT",
    path,
    canonicalQuery,
    `content-type:${contentType}\nhost:${host}\n`,
    "content-type;host",
    "UNSIGNED-PAYLOAD",
  ].join("\n");
  const stringToSign = ["AWS4-HMAC-SHA256", amzDate, scope, await sha256Hex(canonicalRequest)].join("\n");

  let k: ArrayBuffer = await hmac(enc.encode("AWS4" + cfg.secretAccessKey), date);
  k = await hmac(k, region);
  k = await hmac(k, "s3");
  k = await hmac(k, "aws4_request");
  const signature = hex(await hmac(k, stringToSign));

  return `https://${host}${path}?${canonicalQuery}&X-Amz-Signature=${signature}`;
}
