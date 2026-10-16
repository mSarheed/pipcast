import assert from "node:assert/strict";
import { createHarness, bootConfig } from "./test.mjs";

// Raycast's /redirect decodes base64url JSON, then forwards that exact state with encodeURI.
function webRedirect(state, code = "fixture-code") {
  let value;
  let forwarded;
  try {
    value = JSON.parse(Buffer.from(state, "base64url").toString());
    forwarded = state;
  } catch {
    value = JSON.parse(state);
    forwarded = JSON.stringify(value);
  }
  return encodeURI(`${value.scheme ?? "raycast"}://oauth?code=${code}&package_name=Extension&state=${forwarded}`);
}

export async function runOAuthFixtures() {
  let callback;
  const requests = [];
  const harness = createHarness({ stubs: {
    "oauth.authorize": ([url, scheme]) => {
      requests.push({ url, scheme });
      return callback(new URL(url).searchParams.get("state"));
    },
  } });
  harness.boot(bootConfig());
  harness.start("oauth", `
    const { OAuth } = require("@raycast/api");
    exports.default = () => {
      globalThis.makeRequest = async (method = "Web", extraParameters) => {
        globalThis.client = new OAuth.PKCEClient({ redirectMethod: OAuth.RedirectMethod[method], providerName: "Teams & GitHub 日本語 # +" });
        globalThis.request = await client.authorizationRequest({ endpoint: "https://example.test/auth", clientId: "fixture", scope: "repo", extraParameters });
        return { state: request.state, url: request.toURL(), verifier: request.codeVerifier };
      };
      globalThis.signIn = custom => client.authorize(custom ? { url: request.toURL() } : request);
    };
  `, "/oauth.js", "/", "no-view", {});
  await new Promise(resolve => setImmediate(resolve));
  try {
    const first = await harness.call("makeRequest()");
    callback = webRedirect;
    assert.equal((await harness.call("signIn(false)")).authorizationCode, "fixture-code");
    const envelope = JSON.parse(Buffer.from(first.state, "base64url").toString());
    assert.equal(envelope.providerName, "Teams & GitHub 日本語 # +");
    assert.equal(envelope.scheme, "raycast");
    assert.match(envelope.nonce, /^[A-Za-z0-9_-]{22}$/);
    assert.match(first.state, /^[A-Za-z0-9_-]+$/);
    const second = await harness.call("makeRequest()");
    assert.notEqual(first.state, second.state);
    assert.notEqual(first.verifier, second.verifier);
    assert.equal((await harness.call("signIn(true)")).authorizationCode, "fixture-code");
    for (const custom of [false, true]) {
      for (const suffix of ["", "&state=", "&state=wrong", `&state=${second.state}&state=wrong`]) {
        callback = () => `raycast://oauth?code=fixture-code${suffix}`;
        await assert.rejects(harness.call(`signIn(${custom})`), /state/);
      }
      callback = () => webRedirect(first.state);
      await assert.rejects(harness.call(`signIn(${custom})`), /state/);
    }
    callback = state => `raycast://oauth?state=${state}`;
    await assert.rejects(harness.call("signIn(false)"), /no authorization code/);
    callback = state => `raycast://oauth?state=${state}&error=access_denied&error_description=Denied`;
    await assert.rejects(harness.call("signIn(false)"), /Denied/);
    for (const [method, scheme, target] of [
      ["App", "raycast", "raycast://oauth"],
      ["AppURI", "com.raycast", "com.raycast:/oauth"],
      ["ClientIdMetadataDocument", "com.raycast", "com.raycast:/oauth"],
    ]) {
      const request = await harness.call(`makeRequest(${JSON.stringify(method)})`);
      assert.match(request.state, /^[A-Za-z0-9_-]{22}$/);
      callback = state => `${target}?code=direct&state=${state}`;
      assert.equal((await harness.call("signIn(false)")).authorizationCode, "direct");
      assert.equal(requests.at(-1).scheme, scheme);
      callback = () => `${target}?code=direct`;
      await assert.rejects(harness.call("signIn(false)"), /state/);
    }
    const overridden = await harness.call('makeRequest("App", { state: "custom-state", redirect_uri: "raycast://oauth" })');
    callback = state => `raycast://oauth?code=custom&state=${state}`;
    assert.equal((await harness.call("signIn(false)")).authorizationCode, "custom");
    assert.equal((await harness.call("signIn(true)")).authorizationCode, "custom");
    callback = () => `raycast://oauth?code=custom&state=${overridden.state}`;
    await assert.rejects(harness.call("signIn(false)"), /state/);
    await assert.rejects(harness.call("signIn(true)"), /state/);
    callback = () => "raycast://oauth?code=stateless";
    assert.equal((await harness.call('client.authorize({ url: "https://example.test/auth" })')).authorizationCode, "stateless");
    console.log("OAuth redirect regression checks passed");
  } finally {
    harness.stop("oauth");
  }
}

if (import.meta.url === `file://${process.argv[1]}`) {
  runOAuthFixtures().catch(error => {
    console.error(error);
    process.exitCode = 1;
  });
}
