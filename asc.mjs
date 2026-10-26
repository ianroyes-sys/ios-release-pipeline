// App Store Connect API call. usage: node asc.mjs METHOD /v1/path [json | @file]
// Prints the response body on stdout. Exits 0 on 2xx, 1 otherwise (status goes to stderr).
import crypto from 'node:crypto';
import fs from 'node:fs';
import os from 'node:os';

const KID = process.env.ASC_KEY_ID;
const ISS = process.env.ASC_ISSUER_ID;
if (!KID || !ISS) {
  process.stderr.write('set ASC_KEY_ID and ASC_ISSUER_ID (App Store Connect API key)\n');
  process.exit(1);
}
const keyPath = process.env.ASC_KEY_PATH || `${os.homedir()}/.appstoreconnect/private_keys/AuthKey_${KID}.p8`;
const key = fs.readFileSync(keyPath, 'utf8');
const b64 = (o) => Buffer.from(JSON.stringify(o)).toString('base64url');
const now = Math.floor(Date.now() / 1000);
const head = b64({ alg: 'ES256', kid: KID, typ: 'JWT' });
const claims = b64({ iss: ISS, iat: now, exp: now + 1100, aud: 'appstoreconnect-v1' });
const sig = crypto.sign('sha256', Buffer.from(`${head}.${claims}`), { key, dsaEncoding: 'ieee-p1363' }).toString('base64url');

const [method, path, data] = process.argv.slice(2);
const res = await fetch(`https://api.appstoreconnect.apple.com${path}`, {
  method,
  headers: { Authorization: `Bearer ${head}.${claims}.${sig}`, 'Content-Type': 'application/json' },
  body: data ? (data.startsWith('@') ? fs.readFileSync(data.slice(1), 'utf8') : data) : undefined,
});
const txt = await res.text();
process.stdout.write(txt || '{}');
if (!res.ok) {
  process.stderr.write(`ASC ${method} ${path} -> HTTP ${res.status}\n`);
  process.exit(1);
}
