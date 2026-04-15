import type { ExtensionAPI } from "@mariozechner/pi-coding-agent";

/**
 * Safety net to prevent accidental usage of banned providers.
 * 
 * The primary protection is removing auth credentials from ~/.pi/agent/auth.json.
 * This extension provides additional guards:
 * - Warns loudly if a banned provider's models somehow become available
 * - Tries to unregister if it was dynamically registered
 */
export default function (pi: ExtensionAPI) {
  const BLOCKED_PROVIDERS = ["google-antigravity"];

  pi.on("session_start", async (_event, ctx) => {
    // Check if any banned providers have auth configured
    const available = ctx.modelRegistry.getAvailable();
    const banned = available.filter((m) => BLOCKED_PROVIDERS.includes(m.provider));
    if (banned.length > 0) {
      ctx.ui.notify(
        `⚠️ Blocked provider has auth! Remove "${banned[0].provider}" from ~/.pi/agent/auth.json`,
        "error",
      );
    }
  });

  // Best-effort unregister (works for dynamically registered providers only)
  for (const provider of BLOCKED_PROVIDERS) {
    pi.unregisterProvider(provider);
  }
}
