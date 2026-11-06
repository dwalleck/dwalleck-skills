// `vally compare` hard-codes createCopilotLlmClient() with no plugin option, but everything
// after that call takes any LlmClient. Preloaded with --import, this swaps that one import
// for the Kiro client, so pairing, debiasing, statistics and exit codes stay Vally's own.
// compare-judge.test.mjs fails if a Vally upgrade stops this from taking effect.
import { registerHooks } from "node:module";

const SHIM = new URL("./compare-vally-shim.js", import.meta.url).href;

registerHooks({
  resolve(specifier, context, next) {
    if (specifier === "@microsoft/vally" && context.parentURL?.endsWith("/commands/compare.js")) {
      return { url: SHIM, shortCircuit: true };
    }
    return next(specifier, context);
  },
});
