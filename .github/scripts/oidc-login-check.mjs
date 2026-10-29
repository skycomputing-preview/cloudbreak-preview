#!/usr/bin/env node
// The oidc preview's sign-in, end to end, before collaborators get the URL:
// headless Chrome signs in as a persona through the REAL Zitadel login (the
// public auth URL), and the BFF must land an authenticated session with the
// persona's role.
//
// The app's public URL sits behind Cloudflare Access, which a runner cannot
// pass, so the browser talks to the stack's local gateway (GATEWAY) instead.
// Zitadel still redirects to the app's REGISTERED callback
// (`${APP_URL}/callback?code&state`): the check captures that request and
// replays its query on the gateway's /callback. The code is single-use, and
// Access stops the original request before it reaches the BFF.
//
// Env: GATEWAY, APP_URL, AUTH_URL, LOGIN (a persona's email), PASSWORD,
// EXPECT_ROLE (its role label), PW_DIR (where playwright-core is installed).

import { createRequire } from "node:module";

const env = (name) => {
  const v = process.env[name];
  if (!v) throw new Error(`${name} is required`);
  return v;
};
const GATEWAY = env("GATEWAY").replace(/\/$/, "");
const APP_URL = env("APP_URL").replace(/\/$/, "");
const AUTH_URL = env("AUTH_URL").replace(/\/$/, "");
const LOGIN = env("LOGIN");
const { chromium } = createRequire(`${env("PW_DIR")}/`)("playwright-core");

const browser = await chromium.launch({ channel: "chrome" });
try {
  const page = await browser.newPage();
  let callback;
  const callbackSeen = new Promise((resolve) => {
    page.on("request", (req) => {
      if (req.url().startsWith(`${APP_URL}/callback?`)) {
        callback = new URL(req.url());
        resolve();
      }
    });
  });

  await page.goto(`${GATEWAY}/`);
  await page.getByRole("link", { name: "Sign in" }).click();
  await page.waitForURL((u) => u.href.startsWith(AUTH_URL), { timeout: 30_000 });
  await page.fill("#loginName", LOGIN);
  await page.click("#submit-button");
  await page.fill("#password", env("PASSWORD"));
  await page.click("#submit-button");
  // Zitadel's 2FA-setup prompt shows on a user's first login: skip it.
  const skip = page.locator('button[name="skip"]');
  await Promise.race([callbackSeen, skip.waitFor({ state: "visible", timeout: 30_000 })]);
  if (!callback) {
    await skip.click();
    await Promise.race([
      callbackSeen,
      new Promise((_, reject) =>
        setTimeout(() => reject(new Error("no redirect to the app's callback")), 30_000),
      ),
    ]);
  }
  console.log("Zitadel login done; replaying the callback on the gateway");

  await page.goto(`${GATEWAY}/callback${callback.search}`);
  await page.getByTestId("role-indicator").waitFor({ timeout: 30_000 });
  const session = await page.evaluate(async () => {
    const res = await fetch("/api/cb.bff.v1.SessionService/GetSession", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: "{}",
    });
    return res.json();
  });
  if (!session.authenticated || session.userId !== LOGIN) {
    throw new Error(`expected a session for ${LOGIN}, got ${JSON.stringify(session)}`);
  }
  const role = await page.getByTestId("role-indicator").innerText();
  if (!role.includes(env("EXPECT_ROLE"))) {
    throw new Error(`expected role ${env("EXPECT_ROLE")}, the indicator says ${role}`);
  }
  console.log(`signed in through Zitadel: ${session.userId} (${role.trim()})`);
} finally {
  await browser.close();
}
