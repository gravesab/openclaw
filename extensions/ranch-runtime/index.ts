// Ranch Runtime is the Ranch-owned integration boundary for OpenClaw.
// Ranch capabilities register through supported plugin APIs rather than
// modifying OpenClaw Gateway core implementation files.

import { definePluginEntry } from "openclaw/plugin-sdk/plugin-entry";

export default definePluginEntry({
  id: "ranch-runtime",
  name: "Ranch Runtime",
  description: "Ranch-owned integration boundary for AI Intelligence and Trusted Records.",

  register(api) {
    api.registerGatewayMethod(
      "ranch.runtime.status",
      async ({ respond }) => {
        respond(true, {
          ok: true,
          plugin: "ranch-runtime",
          openclawBaseline: "2026.8.1-beta.2",
          capabilities: {
            aiIntelligence: "pending-migration",
            trustedRecords: "pending-migration",
          },
        });
      },
      { scope: "operator.read" },
    );
  },
});
