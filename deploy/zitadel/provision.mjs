#!/usr/bin/env node
// T12 → B03 → W4-F-5 — Zitadel dev-realm provisioning (host-run, idempotent).
// Run after `docker compose -f deploy/compose.dev.yml up -d` (and after every
// `down -v`): waits for the issuer, authenticates with the first-instance
// machine-user PAT the zitadel container wrote to ./.state/pat, then ensures
//   - project "cloudbreak" (role assertion on) with the SEVEN role keys (the
//     bff's `ROLE_CLAIM_KEYS`, session.ts — one per CloudBreak role, the
//     Infra Owner's since W4-F-5),
//   - the BFF's OIDC app: code + PKCE, public client (no secret), devMode so
//     http://localhost redirect URIs are allowed — client id written to
//     ./.state/client_id for the BFF (OIDC_CLIENT_ID_FILE),
//   - the BFF's pending-login seal key (W4-H-4): 32 random bytes, base64, in
//     ./.state/cookie_seal_key (COOKIE_SEAL_KEY_FILE) — written ONCE and kept
//     across re-runs, so a BFF restart keeps a login in flight valid,
//   - the human users FROM THE WORLD FILE (`worlds/acme.yaml`, or the file
//     `--world <path>` names; Discovery #48, W4-F-5): `settings.users[]` is the
//     ONE roster — each with a verified email, the fixed dev password and one
//     role grant. NO scope metadata (Q1 a″: scope is derived from the rows the
//     core holds, never stored — in the IdP or anywhere).
// Modes: (no args) provision · --verify admin-API assertions ·
// --delete-user <email> deprovision (terminate sessions + remove user).
// Host-run on purpose: zitadel resolves its instance by Host header
// (localhost:8200), which a sibling container cannot present without host
// networking. Everything here is dev bootstrap — production provisioning is
// FE02a's problem. Zero deps of its own: the YAML parser is BORROWED from
// the dev-fixtures package's resolution (the world loader's `yaml`), so the
// file is read exactly as `real-core seed` reads it.

import { randomBytes } from "node:crypto";
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { createRequire } from "node:module";
import { fileURLToPath } from "node:url";

const ISSUER = process.env.ZITADEL_ISSUER ?? "http://localhost:8200";
const STATE_DIR = fileURLToPath(new URL("./.state/", import.meta.url));
const DEFAULT_WORLD = fileURLToPath(new URL("../../worlds/acme.yaml", import.meta.url));
const PROJECT_NAME = "cloudbreak";
const APP_NAME = "cloudbreak-bff";
// 5173 = dev Vite, 5174 = the verify suite's AUTH_MODE=oidc Vite instance.
const REDIRECT_URIS = ["http://localhost:5173/callback", "http://localhost:5174/callback"];
const POST_LOGOUT_URIS = ["http://localhost:5173/", "http://localhost:5174/"];
// Fixed dev credential (meets zitadel's default complexity policy); the
// t12-login Playwright spec types it. Dev-only — never a pattern to copy.
export const PASSWORD = "Stage0-Passw0rd!";

// The role-claim key per CloudBreak role — EXACTLY the bff's `ROLE_CLAIM_KEYS`
// (bff/src/session.ts): `principalFromClaims` maps a token's role-claim key
// to a Role, and the row in the core's `SystemSettings.users[]` must AGREE
// (the cross-check, `bindIdentity`). By copy, not imported (quarantine rule).
const ROLE_KEY_OF = {
  ROLE_RD_OWNER: "rd-owner",
  ROLE_BUSINESS_OWNER: "business-owner",
  ROLE_CLOUD_BREAK_SUPERVISOR: "supervisor",
  ROLE_SYSTEM_ADMIN: "sysadmin",
  ROLE_PROCUREMENT_OWNER: "procurement",
  ROLE_APPLICATION_OWNER: "appowner",
  ROLE_INFRA_OWNER: "infra-owner",
};
const ROLE_KEYS = Object.values(ROLE_KEY_OF);

/**
 * The users, FROM THE WORLD FILE: `settings.users[]` as `real-core seed` and
 * `fake-core` read it (the protobuf JSON of `cb.core.v1.User` — `email`,
 * `role` as the enum name, `active`, `displayName`). The display name splits
 * into Zitadel's given/family on the LAST space ("C. B. Supervisor" → "C. B."
 * + "Supervisor"); a one-word name is its own family name. An INACTIVE row is
 * still provisioned (the IdP knows the person; the core refuses the session).
 */
function usersFromWorld(path) {
  // The dev-fixtures package's `yaml` — the same parser the world loader uses.
  const requireFromFixtures = createRequire(
    new URL("../../dev-fixtures/package.json", import.meta.url),
  );
  const { parse } = requireFromFixtures("yaml");
  const doc = parse(readFileSync(path, "utf8"));
  const rows = doc?.settings?.users;
  if (!Array.isArray(rows) || rows.length === 0) {
    throw new Error(`${path}: settings.users is missing or empty — nothing to provision`);
  }
  return rows.map((row, i) => {
    const role = ROLE_KEY_OF[row.role];
    if (typeof row.email !== "string" || row.email === "") {
      throw new Error(`${path}: settings.users[${i}] has no email`);
    }
    if (role === undefined) {
      throw new Error(`${path}: settings.users[${i}] (${row.email}) has an unknown role ${row.role}`);
    }
    const displayName = typeof row.displayName === "string" && row.displayName !== "" ? row.displayName : row.email;
    const cut = displayName.lastIndexOf(" ");
    return {
      userName: row.email,
      givenName: cut === -1 ? "" : displayName.slice(0, cut),
      familyName: cut === -1 ? displayName : displayName.slice(cut + 1),
      role,
    };
  });
}

// Read lazily and re-read while waiting: the .state bind mount survives
// `compose down -v`, so right after a reset the file may still hold the OLD
// instance's PAT until zitadel's first-run init overwrites it.
let pat = "";

async function api(path, { method = "GET", body } = {}) {
  const res = await fetch(`${ISSUER}${path}`, {
    method,
    headers: { authorization: `Bearer ${pat}`, "content-type": "application/json" },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  const json = await res.json().catch(() => ({}));
  if (!res.ok) {
    const err = new Error(`${method} ${path} → ${res.status}: ${JSON.stringify(json)}`);
    err.status = res.status;
    err.detail = json;
    throw err;
  }
  return json;
}

// Zitadel signals "already exists" with HTTP 409 (gRPC AlreadyExists).
async function ensure(fn) {
  try {
    return await fn();
  } catch (err) {
    if (err.status === 409) return undefined;
    throw err;
  }
}

async function waitForIssuer() {
  // Discovery answers before the management API finishes first-run init, so
  // probe an authenticated management call until it stops erroring. A 401/403
  // here usually means the PAT on disk is still the previous instance's —
  // keep re-reading; init overwrites it.
  for (let i = 0; i < 90; i++) {
    try {
      pat = readFileSync(`${STATE_DIR}pat`, "utf8").trim();
      const res = await fetch(`${ISSUER}/auth/v1/users/me`, {
        headers: { authorization: `Bearer ${pat}` },
      });
      if (res.ok) return;
    } catch {
      // not up yet (fetch failed) or PAT file missing — retry
    }
    await new Promise((r) => setTimeout(r, 2000));
  }
  throw new Error(
    `zitadel not ready at ${ISSUER} after 180s — is compose up? (stale .state/pat also lands here)`,
  );
}

async function ensureProject() {
  const search = await api("/management/v1/projects/_search", {
    method: "POST",
    body: { queries: [{ nameQuery: { name: PROJECT_NAME, method: "TEXT_QUERY_METHOD_EQUALS" } }] },
  });
  const existing = search.result?.[0];
  if (existing) return existing.id;
  // projectRoleAssertion ⇒ role claims ride every token for this project's
  // apps without extra scopes — keeps the BFF's scope list provider-agnostic.
  const created = await api("/management/v1/projects", {
    method: "POST",
    body: { name: PROJECT_NAME, projectRoleAssertion: true },
  });
  return created.id;
}

async function ensureRoles(projectId) {
  for (const roleKey of ROLE_KEYS) {
    await ensure(() =>
      api(`/management/v1/projects/${projectId}/roles`, {
        method: "POST",
        body: { roleKey, displayName: roleKey },
      }),
    );
  }
}

// B04 adds the refresh-token grant: the BFF requests offline_access and runs
// the silent-refresh grant, which Zitadel only serves to apps carrying it.
const APP_OIDC_CONFIG = {
  redirectUris: REDIRECT_URIS,
  postLogoutRedirectUris: POST_LOGOUT_URIS,
  responseTypes: ["OIDC_RESPONSE_TYPE_CODE"],
  grantTypes: ["OIDC_GRANT_TYPE_AUTHORIZATION_CODE", "OIDC_GRANT_TYPE_REFRESH_TOKEN"],
  appType: "OIDC_APP_TYPE_WEB",
  // Public client + PKCE (FE-ADR-006's flow; the BFF still runs it
  // server-side). No secret to plumb through dev config.
  authMethodType: "OIDC_AUTH_METHOD_TYPE_NONE",
  accessTokenType: "OIDC_TOKEN_TYPE_BEARER",
  idTokenRoleAssertion: true,
  idTokenUserinfoAssertion: true,
  devMode: true, // allows the http:// redirect URIs above
};

async function ensureApp(projectId) {
  const search = await api(`/management/v1/projects/${projectId}/apps/_search`, {
    method: "POST",
    body: { queries: [{ nameQuery: { name: APP_NAME, method: "TEXT_QUERY_METHOD_EQUALS" } }] },
  });
  const existing = search.result?.[0];
  if (existing?.oidcConfig?.clientId) {
    // Reconcile an app provisioned before B04 in place (idempotent: skip
    // when the grant list already matches).
    const grants = existing.oidcConfig.grantTypes ?? [];
    if (!APP_OIDC_CONFIG.grantTypes.every((g) => grants.includes(g))) {
      await api(`/management/v1/projects/${projectId}/apps/${existing.id}/oidc_config`, {
        method: "PUT",
        body: APP_OIDC_CONFIG,
      });
    }
    return existing.oidcConfig.clientId;
  }
  const created = await api(`/management/v1/projects/${projectId}/apps/oidc`, {
    method: "POST",
    body: { name: APP_NAME, ...APP_OIDC_CONFIG },
  });
  return created.clientId;
}

async function findUser(userName) {
  const search = await api("/management/v1/users/_search", {
    method: "POST",
    body: { queries: [{ userNameQuery: { userName, method: "TEXT_QUERY_METHOD_EQUALS" } }] },
  });
  return search.result?.[0];
}

async function ensureUser({ userName, givenName, familyName }) {
  const existing = await findUser(userName);
  if (existing) return existing.id;
  const created = await api("/management/v1/users/human/_import", {
    method: "POST",
    body: {
      userName,
      profile: {
        firstName: givenName,
        lastName: familyName,
        displayName: `${givenName} ${familyName}`,
      },
      email: { email: userName, isEmailVerified: true },
      password: PASSWORD,
      passwordChangeRequired: false,
    },
  });
  return created.userId;
}

// One role grant each; an existing grant whose roleKeys drifted (console
// edit, persona re-keying) is UPDATED — re-runs converge on the config
// rather than reporting green over stale roles.
async function ensureGrant(userId, projectId, role) {
  const existing = (
    await searchGrants([{ projectIdQuery: { projectId } }, { userIdQuery: { userId } }])
  )[0];
  if (!existing) {
    await api(`/management/v1/users/${userId}/grants`, {
      method: "POST",
      body: { projectId, roleKeys: [role] },
    });
  } else if (!sameSet(existing.roleKeys ?? [], [role])) {
    await api(`/management/v1/users/${userId}/grants/${existing.id}`, {
      method: "PUT",
      body: { roleKeys: [role] },
    });
  }
}

// W4-F-5: the B03 scope METADATA (`costCenters` / `siteNames` /
// `workloadNames` per user) and the BO-per-cost-center check over it are
// GONE — the one Business Owner per cost center is the world file's R1, and
// a user's scope is derived from the rows the core holds (Q1 a″). A realm
// provisioned before W4-F-5 keeps its stale metadata entries; nothing reads
// them.

async function searchGrants(queries) {
  const search = await api("/management/v1/users/grants/_search", {
    method: "POST",
    body: { queries },
  });
  return search.result ?? [];
}

// Deprovision = revoke (FE02a): terminate every active session BEFORE the
// user record goes away, then remove the user (grants die with it). A
// re-provision run restores the persona — that round trip is the idempotency
// proof --verify exercises.
async function deleteUser(userName) {
  const user = await findUser(userName);
  if (!user) {
    console.log(`delete-user: ${userName} already absent — nothing to do`);
    return;
  }
  // The search is paged — loop until NO sessions remain; revoke-before-delete
  // must not silently depend on the default page size.
  let terminated = 0;
  for (let round = 0; ; round++) {
    const { sessions = [] } = await api("/v2/sessions/search", {
      method: "POST",
      body: { queries: [{ userIdQuery: { id: user.id } }] },
    });
    if (sessions.length === 0) break;
    if (round >= 20)
      throw new Error(`delete-user: sessions for ${userName} still present after 20 rounds`);
    for (const s of sessions) {
      await api(`/v2/sessions/${s.id}`, { method: "DELETE", body: {} });
    }
    terminated += sessions.length;
  }
  await api(`/management/v1/users/${user.id}`, { method: "DELETE" });
  console.log(`delete-user: removed ${userName} (${user.id}), terminated ${terminated} session(s)`);
}

// The ONE per-user provisioning path — provision() and --verify's restore
// both go through here, so the round-trip proof cannot drift from what
// provisioning actually writes.
async function provisionUser(projectId, u) {
  const userId = await ensureUser(u);
  await ensureGrant(userId, projectId, u.role);
  return userId;
}

async function provision() {
  const projectId = await ensureProject();
  await ensureRoles(projectId);
  const clientId = await ensureApp(projectId);
  for (const u of USERS) {
    await provisionUser(projectId, u);
  }
  writeFileSync(`${STATE_DIR}client_id`, `${clientId}\n`);
  // The seal key is minted ONCE: a re-run must not rotate it under a BFF that
  // is already running with the old one (every login in flight would fail).
  const sealKeyFile = `${STATE_DIR}cookie_seal_key`;
  const sealKeyFresh = !existsSync(sealKeyFile);
  if (sealKeyFresh) {
    writeFileSync(sealKeyFile, `${randomBytes(32).toString("base64")}\n`, { mode: 0o600 });
  }
  console.log(
    `zitadel provisioned from ${WORLD_PATH}: project ${projectId}, client ${clientId} (→ ${STATE_DIR}client_id), seal key ${sealKeyFresh ? "minted" : "kept"} (→ ${sealKeyFile}), users: ${USERS.map((u) => `${u.userName} [${u.role}]`).join(", ")}`,
  );
}

// --verify: admin-API assertions only (the browser OIDC round-trip stays a
// documented manual check in README.md; the automated round-trip is T06/FE16a).
function assert(cond, label) {
  if (!cond) throw new Error(`verify FAILED: ${label}`);
  console.log(`ok: ${label}`);
}

function sameSet(a, b) {
  return a.length === b.length && [...a].sort().every((v, i) => v === [...b].sort()[i]);
}

// The ONE per-user assertion pair — the roster sweep and the post-restore
// check share it, mirroring provisionUser on the write side.
async function assertUserState(projectId, u) {
  const user = await findUser(u.userName);
  assert(user !== undefined, `user ${u.userName} exists`);
  const grants = await searchGrants([
    { projectIdQuery: { projectId } },
    { userIdQuery: { userId: user.id } },
  ]);
  assert(
    grants.length === 1 && sameSet(grants[0].roleKeys ?? [], [u.role]),
    `user ${u.userName} has exactly the ${u.role} grant`,
  );
}

async function verify() {
  const search = await api("/management/v1/projects/_search", {
    method: "POST",
    body: { queries: [{ nameQuery: { name: PROJECT_NAME, method: "TEXT_QUERY_METHOD_EQUALS" } }] },
  });
  const project = search.result?.[0];
  assert(project !== undefined, `project ${PROJECT_NAME} exists`);
  const projectId = project.id;

  // Exactly the seven roles — extras fail too (W4-F-5: the Infra Owner's is
  // the seventh).
  const roles = await api(`/management/v1/projects/${projectId}/roles/_search`, {
    method: "POST",
    body: { queries: [] },
  });
  const roleKeys = (roles.result ?? []).map((r) => r.key);
  assert(
    sameSet(roleKeys, ROLE_KEYS),
    `project has exactly the seven roles (got: ${roleKeys.sort().join(", ")})`,
  );

  // Every user of the world file: present, exactly one grant carrying
  // exactly their role — the Infra Owner included.
  for (const u of USERS) {
    await assertUserState(projectId, u);
  }
  assert(
    USERS.some((u) => u.role === "infra-owner"),
    `the world file names an Infra Owner (${USERS.filter((u) => u.role === "infra-owner").map((u) => u.userName).join(", ")})`,
  );

  // delete ⇒ revoke, asserted via the session + user-grant APIs, on a probe
  // persona with a real (password-checked) session; then the same ensure path
  // restores it — the FE02a deprovision/re-provision round trip.
  const probe = USERS.find((u) => u.role === "appowner");
  const before = await findUser(probe.userName);
  const session = await api("/v2/sessions", {
    method: "POST",
    body: { checks: { user: { loginName: probe.userName }, password: { password: PASSWORD } } },
  });
  assert(typeof session.sessionId === "string", `probe session created for ${probe.userName}`);
  try {
    await deleteUser(probe.userName);
    assert((await findUser(probe.userName)) === undefined, `${probe.userName} removed`);
    const leftoverSessions = await api("/v2/sessions/search", {
      method: "POST",
      body: { queries: [{ userIdQuery: { id: before.id } }] },
    });
    assert(
      (leftoverSessions.sessions ?? []).length === 0,
      `${probe.userName} has no active sessions after delete`,
    );
    const leftoverGrants = await searchGrants([{ userIdQuery: { userId: before.id } }]);
    assert(leftoverGrants.length === 0, `${probe.userName} has no grants after delete`);
  } finally {
    // Whatever failed above, --verify may not leave the realm deprovisioned
    // (README: mutates only the probe persona AND restores it).
    await provisionUser(projectId, probe);
  }
  await assertUserState(projectId, probe);
  console.log(`ok: ${probe.userName} restored by re-provision`);

  console.log("verify: all assertions green");
}

// Validate argv BEFORE the (up to 180s) issuer wait so a typo'd flag fails
// fast with usage, not a misleading "zitadel not ready". `--world <path>`
// (W4-F-5) names the world file to read the users from; the default is the
// acme world.
const argv = process.argv.slice(2);
let WORLD_PATH = DEFAULT_WORLD;
const worldAt = argv.indexOf("--world");
if (worldAt !== -1) {
  const path = argv[worldAt + 1];
  if (path === undefined || path.startsWith("--")) {
    throw new Error("usage: provision.mjs [--world <path>] [--verify | --delete-user <email>]");
  }
  WORLD_PATH = path;
  argv.splice(worldAt, 2);
}
const mode = argv[0];
if (mode !== undefined && mode !== "--verify" && mode !== "--delete-user") {
  throw new Error(
    `unknown arguments: ${argv.join(" ")} (modes: none | --verify | --delete-user <email>; --world <path> before any)`,
  );
}
if (mode === "--verify" && argv.length > 1) {
  throw new Error(`--verify takes no further arguments (got: ${argv.slice(1).join(" ")})`);
}
if (mode === "--delete-user" && argv.length !== 2) {
  throw new Error("usage: provision.mjs --delete-user <email> (exactly one email)");
}
// The world file is read BEFORE the issuer wait too: a missing or malformed
// file fails fast, and `--delete-user` needs no roster.
const USERS = mode === "--delete-user" ? [] : usersFromWorld(WORLD_PATH);
await waitForIssuer();
if (mode === "--verify") {
  await verify();
} else if (mode === "--delete-user") {
  await deleteUser(argv[1]);
} else {
  await provision();
}
