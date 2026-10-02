import { describe, expect, it, vi } from "vitest";
import { handleWorkspaceGatewayConnect } from "../src/routes/workspaces-runtime.js";

describe("Workspace WebSocket runtime authentication", () => {
  it.each(["token", "authToken"])(
    "does not accept the %s query parameter as a credential",
    async (parameter) => {
      const prepare = vi.fn();
      const response = await handleWorkspaceGatewayConnect(
        new Request(
          `https://app.conclave.test/api/workspace-gateway/connect?workspaceRuntimeId=runtime-1&${parameter}=secret`,
          { headers: { upgrade: "websocket" } },
        ),
        { CONCLAVE_DB: { prepare } } as never,
      );

      expect(response.status).toBe(401);
      expect(prepare).not.toHaveBeenCalled();
    },
  );
});
