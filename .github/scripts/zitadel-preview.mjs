#!/usr/bin/env node
// Preview-only fix-ups after the vendored deploy/zitadel/provision.mjs has
// provisioned the realm (project, roles, the cloudbreak-bff app, the world's
// users). provision.mjs is written for localhost dev, so two things differ in
// the preview, and they are set here through the same management API it uses:
//
// 1. The app's redirect URIs: the preview's `${APP_URL}/callback` and
//    `${APP_URL}/` (post-logout) are ADDED to provision.mjs's localhost ones.
// 2. Every human user's password: provision.mjs sets a fixed dev password,
//    and this repo is public, so each persona gets USER_PASSWORD (a secret
//    shared with collaborators) instead, with no forced change.
//
// Env: ZITADEL_ISSUER (the auth URL), STATE_DIR (holds the provisioner's
// PAT), APP_URL (the app's public base URL), USER_PASSWORD.

import { readFileSync } from "node:fs";

const env = (name) => {
  const v = process.env[name];
  if (!v) throw new Error(`${name} is required`);
  return v;
};
const ISSUER = env("ZITADEL_ISSUER").replace(/\/$/, "");
const APP_URL = env("APP_URL").replace(/\/$/, "");
const PASSWORD = env("USER_PASSWORD");
const PAT = readFileSync(`${env("STATE_DIR").replace(/\/$/, "")}/pat`, "utf8").trim();

async function api(path, { method = "GET", body } = {}) {
  const res = await fetch(`${ISSUER}${path}`, {
    method,
    headers: { authorization: `Bearer ${PAT}`, "content-type": "application/json" },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  const text = await res.text();
  if (!res.ok) throw new Error(`${method} ${path}: HTTP ${res.status} ${text.slice(0, 300)}`);
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

async function addRedirectUris() {
  const projects = await api("/management/v1/projects/_search", {
    method: "POST",
    body: { queries: [byName("cloudbreak")] },
  });
  const projectId = projects.result?.[0]?.id;
  if (!projectId) throw new Error("project cloudbreak not found: did provision.mjs run?");
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

async function setPasswords() {
  const users = await api("/management/v1/users/_search", {
    method: "POST",
    body: { queries: [{ typeQuery: { type: "TYPE_HUMAN" } }] },
  });
  const humans = users.result ?? [];
  if (humans.length === 0) throw new Error("no human users: did provision.mjs run?");
  for (const user of humans) {
    await api(`/management/v1/users/${user.id}/password`, {
      method: "POST",
      body: { password: PASSWORD, noChangeRequired: true },
    });
  }
  console.log(`${humans.length} users: password set from CB_PREVIEW_OIDC_PASSWORD`);
}

await addRedirectUris();
await setPasswords();
