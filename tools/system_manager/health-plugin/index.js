import { readFile } from "node:fs/promises";
import { join } from "node:path";

export default {
  id: "system-health",
  name: "System Health",
  register(api) {
    for (const name of ["health"]) {
      api.registerCommand({
        name,
        description: "System health and backup freshness",
        requireAuth: true,
        acceptsArgs: false,
        handler: async () => {
          try {
            const report = JSON.parse(await readFile(join(api.runtime.state.resolveStateDir(), "system-health/report.json"), "utf8"));
            const age = Date.now() / 1000 - report.checked_epoch;
            if (!Number.isFinite(age) || age < -300 || age > 900) {
              return { text: "System health: Unknown. Health collector has not refreshed within 15 minutes." };
            }
            return { text: report.text };
          } catch {
            return { text: "System health: Unknown. Health report unavailable." };
          }
        },
      });
    }
  },
};
