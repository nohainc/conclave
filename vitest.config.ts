import { defineConfig } from "vitest/config";
import { fileURLToPath, URL } from "node:url";

export default defineConfig({
  resolve: {
    alias: {
      "cloudflare:workers": fileURLToPath(
        new URL("./apps/cloud/test/cloudflare-workers.ts", import.meta.url),
      ),
    },
  },
});
