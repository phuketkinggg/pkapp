// Checks a JWS signed by the App Store (a StoreKit 2 transaction, or a server notification) and returns its payload.
// The x5c chain in the header must lead to Apple Root CA - G3 (pinned by its SHA-256 fingerprint), each certificate signed by the next,
// the leaf and intermediate must carry Apple's App Store receipt markers, and the JWS must be signed (ES256) by the leaf.
import * as x509 from "npm:@peculiar/x509@1.12.3";
x509.cryptoProvider.set(crypto);

export const APPLE_ROOT_G3 = "63343abfb89a6a03ebb57e9b3f5fa7be7c4f5c756f3017b3a8c488c3653e9179";
const LEAF_OID = "1.2.840.113635.100.6.11.1"; // App Store receipt signing
const MID_OID = "1.2.840.113635.100.6.2.1"; // Apple Worldwide Developer Relations intermediate

function b64url(s: string): Uint8Array {
  s = s.replace(/-/g, "+").replace(/_/g, "/"); while (s.length % 4) s += "=";
  return Uint8Array.from(atob(s), (c) => c.charCodeAt(0));
}
async function sha256hex(b: ArrayBuffer): Promise<string> {
  return Array.from(new Uint8Array(await crypto.subtle.digest("SHA-256", b))).map((x) => x.toString(16).padStart(2, "0")).join("");
}

export async function verifyAppleJws(jws: string, rootFingerprint = APPLE_ROOT_G3, checkOids = true): Promise<Record<string, unknown>> {
  const parts = String(jws || "").split(".");
  if (parts.length !== 3) throw new Error("Not a signed Apple receipt.");
  const header = JSON.parse(new TextDecoder().decode(b64url(parts[0])));
  if (header.alg !== "ES256" || !Array.isArray(header.x5c) || header.x5c.length < 3) throw new Error("Not a signed Apple receipt.");
  const certs = header.x5c.map((c: string) => new x509.X509Certificate(Uint8Array.from(atob(c), (ch) => ch.charCodeAt(0))));
  if (await sha256hex(certs[certs.length - 1].rawData) !== rootFingerprint) throw new Error("The receipt is not signed by Apple.");
  for (let i = 0; i < certs.length - 1; i++) {
    const ok = await certs[i].verify({ publicKey: certs[i + 1].publicKey, signatureOnly: true });
    if (!ok) throw new Error("The receipt's certificates do not match.");
  }
  if (checkOids && (!certs[0].getExtension(LEAF_OID) || !certs[1].getExtension(MID_OID))) throw new Error("The receipt is not from the App Store.");
  const key = await certs[0].publicKey.export({ name: "ECDSA", namedCurve: "P-256" }, ["verify"]);
  const ok = await crypto.subtle.verify({ name: "ECDSA", hash: "SHA-256" }, key, b64url(parts[2]), new TextEncoder().encode(parts[0] + "." + parts[1]));
  if (!ok) throw new Error("The receipt's signature is not right.");
  return JSON.parse(new TextDecoder().decode(b64url(parts[1])));
}
