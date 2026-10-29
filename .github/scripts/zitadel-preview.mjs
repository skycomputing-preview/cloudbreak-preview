#!/usr/bin/env node
// Preview-only fix-ups after the vendored deploy/zitadel/provision.mjs has
// provisioned the realm (project, roles, the cloudbreak-bff app, the world's
// users). provision.mjs is written for localhost dev, so two things differ in
// the preview, and they are set here through the same management API it uses:
//
// 1. The app's redirect URIs: the preview's `${APP_URL}/callback` and
//    `${APP_URL}/` (post-logout) are ADDED to provision.mjs's localhost ones.
// 2. The personas' password: provision.mjs sets a fixed dev password, and
//    this repo is public, so each persona gets USER_PASSWORD (a secret shared
//    with collaborators) instead, with no forced change. A persona is a user
//    with a role grant on the cloudbreak project, i.e. a world-file user: any
//    other human in the org (an admin Zitadel might create) keeps its own
//    password, so the shared one never opens the console.
// 3. Optionally, a Zitadel console admin (ADMIN_PASSWORD set): the human user
//    ADMIN_LOGIN, an ORG_OWNER of acme, so a maintainer can create the IdP
//    account and role grant that a user created in CloudBreak's Settings
//    needs before it can sign in (the core rows and Zitadel are not synced).
//    ORG_OWNER covers the org's users, grants and projects, not the instance.
//    It has no cloudbreak grant, so it is no persona: the app refuses it, and
//    USER_PASSWORD never reaches it.
//
// Env: ZITADEL_ISSUER (the auth URL), STATE_DIR (holds the provisioner's
// PAT), APP_URL (the app's public base URL), USER_PASSWORD, and optionally
// ADMIN_PASSWORD.

import { readFileSync } from "node:fs";

const env = (name) => {
  const v = process.env[name];
  if (!v) throw new Error(`${name} is required`);
  return v;
};
const ISSUER = env("ZITADEL_ISSUER").replace(/\/$/, "");
const APP_URL = env("APP_URL").replace(/\/$/, "");
const PASSWORD = env("USER_PASSWORD");
const ADMIN_PASSWORD = process.env.ADMIN_PASSWORD ?? "";
const ADMIN_LOGIN = "zitadel-admin@acme.example";
const PAT = readFileSync(`${env("STATE_DIR").replace(/\/$/, "")}/pat`, "utf8").trim();

async function api(path, { method = "GET", body } = {}) {
  const res = await fetch(`${ISSUER}${path}`, {
    method,
    headers: { authorization: `Bearer ${PAT}`, "content-type": "application/json" },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  const text = await res.text();
  if (!res.ok) {
    throw Object.assign(new Error(`${method} ${path}: HTTP ${res.status} ${text.slice(0, 300)}`), {
      status: res.status,
    });
  }
  return text ? JSON.parse(text) : {};
}

const byName = (name) => ({ nameQuery: { name, method: "TEXT_QUERY_METHOD_EQUALS" } });

// The fields UpdateOIDCAppConfig takes; everything else on the app's
// oidcConfig (clientId, compliance notes, …) is read-only.
const OIDC_CONFIG_FIELDS = [
  "redirectUris",
  "responseTypes",
  "grantTypes",
  "appType",
  "authMethodType",
  "postLogoutRedirectUris",
  "devMode",
  "accessTokenType",
  "accessTokenRoleAssertion",
  "idTokenRoleAssertion",
  "idTokenUserinfoAssertion",
  "clockSkew",
  "additionalOrigins",
  "skipNativeAppSuccessPage",
  "backChannelLogoutUri",
];

async function findProjectId() {
  const projects = await api("/management/v1/projects/_search", {
    method: "POST",
    body: { queries: [byName("cloudbreak")] },
  });
  const projectId = projects.result?.[0]?.id;
  if (!projectId) throw new Error("project cloudbreak not found: did provision.mjs run?");
  return projectId;
}

async function addRedirectUris(projectId) {
  const apps = await api(`/management/v1/projects/${projectId}/apps/_search`, {
    method: "POST",
    body: { queries: [byName("cloudbreak-bff")] },
  });
  const app = apps.result?.[0];
  if (!app?.oidcConfig) throw new Error("app cloudbreak-bff not found: did provision.mjs run?");
  const config = Object.fromEntries(
    OIDC_CONFIG_FIELDS.filter((f) => app.oidcConfig[f] !== undefined).map((f) => [
      f,
      app.oidcConfig[f],
    ]),
  );
  const add = (list, uri) => [...new Set([...(list ?? []), uri])];
  config.redirectUris = add(config.redirectUris, `${APP_URL}/callback`);
  config.postLogoutRedirectUris = add(config.postLogoutRedirectUris, `${APP_URL}/`);
  await api(`/management/v1/projects/${projectId}/apps/${app.id}/oidc_config`, {
    method: "PUT",
    body: config,
  });
  console.log(`app cloudbreak-bff: ${config.redirectUris.length} redirect URIs (preview added)`);
}

async function setPersonaPasswords(projectId) {
  const grants = await api("/management/v1/users/grants/_search", {
    method: "POST",
    body: { queries: [{ projectIdQuery: { projectId } }] },
  });
  const personas = [...new Set((grants.result ?? []).map((g) => g.userId))];
  if (personas.length === 0) throw new Error("no persona grants: did provision.mjs run?");
  for (const userId of personas) {
    await api(`/management/v1/users/${userId}/password`, {
      method: "POST",
      body: { password: PASSWORD, noChangeRequired: true },
    });
  }
  console.log(`${personas.length} personas: password set from CB_PREVIEW_OIDC_PASSWORD`);
}

async function ensureConsoleAdmin() {
  const found = await api("/management/v1/users/_search", {
    method: "POST",
    body: {
      queries: [{ userNameQuery: { userName: ADMIN_LOGIN, method: "TEXT_QUERY_METHOD_EQUALS" } }],
    },
  });
  let userId = found.result?.[0]?.id;
  if (userId) {
    await api(`/management/v1/users/${userId}/password`, {
      method: "POST",
      body: { password: ADMIN_PASSWORD, noChangeRequired: true },
    });
  } else {
    const created = await api("/management/v1/users/human/_import", {
      method: "POST",
      body: {
        userName: ADMIN_LOGIN,
        profile: { firstName: "Preview", lastName: "Admin", displayName: "Preview Admin" },
        email: { email: ADMIN_LOGIN, isEmailVerified: true },
        password: ADMIN_PASSWORD,
        passwordChangeRequired: false,
      },
    });
    userId = created.userId;
  }
  const member = { userId, roles: ["ORG_OWNER"] };
  try {
    await api("/management/v1/orgs/me/members", { method: "POST", body: member });
  } catch (err) {
    if (err.status !== 409) throw err;
    await api(`/management/v1/orgs/me/members/${userId}`, { method: "PUT", body: member });
  }
  // The password signs in: a password-checked session, then dropped.
  const session = await api("/v2/sessions", {
    method: "POST",
    body: { checks: { user: { loginName: ADMIN_LOGIN }, password: { password: ADMIN_PASSWORD } } },
  });
  await api(`/v2/sessions/${session.sessionId}`, { method: "DELETE", body: {} });
  console.log(`console admin ${ADMIN_LOGIN}: ORG_OWNER, password from CB_PREVIEW_ADMIN_PASSWORD`);
}

const projectId = await findProjectId();
await addRedirectUris(projectId);
await setPersonaPasswords(projectId);
if (ADMIN_PASSWORD) await ensureConsoleAdmin();
else console.log("no CB_PREVIEW_ADMIN_PASSWORD: no console admin");
