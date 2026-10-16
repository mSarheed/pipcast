import { performance } from "node:perf_hooks";
import { statSync } from "node:fs";
import { resolve } from "node:path";
import { createHarness, bootConfig } from "./test.mjs";

const samples = [];
for (let round = 0; round < 9; round++) {
  const start = performance.now();
  const harness = createHarness();
  harness.boot(bootConfig());
  const boot = performance.now() - start;
  harness.start("bench", `
    const { OAuth } = require("@raycast/api");
    exports.default = async () => {
      const client = new OAuth.PKCEClient({ redirectMethod: OAuth.RedirectMethod.Web, providerName: "GitHub" });
      globalThis.requestBatch = async (count) => {
        for (let i = 0; i < count; i++) {
          const request = await client.authorizationRequest({ endpoint: "https://example.test/auth", clientId: "fixture", scope: "repo" });
          request.toURL();
        }
      };
    };
  `, "/bench.js", "/", "no-view", {});
  await new Promise(resolve => setImmediate(resolve));
  await harness.call("requestBatch(100)");
  const requestsStart = performance.now();
  await harness.call("requestBatch(2000)");
  samples.push({ bootMs: boot, requestUs: (performance.now() - requestsStart) * 1000 / 2000 });
  harness.stop("bench");
}
const median = key => samples.map(sample => sample[key]).sort((a, b) => a - b)[4];
console.log(JSON.stringify({ node: process.version, arch: process.arch, rounds: 9, requestsPerRound: 2000,
  runtimeBytes: statSync(resolve("Pipcast/Resources/RaycastRuntime.generated.js")).size,
  medianBootMs: median("bootMs"), medianRequestUs: median("requestUs"), samples }, null, 2));
