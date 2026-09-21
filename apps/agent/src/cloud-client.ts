import {
  AGENT_PROTOCOL_NAME,
  AGENT_PROTOCOL_VERSION,
  parseAgentMessage,
  serializeAgentMessage,
  type AgentProtocolMessage,
  type AgentHelloPayload,
  type AgentHelloAckPayload,
  type AgentHeartbeatPayload,
  type AgentHeartbeatAckPayload,
  type AgentSyncRequestPayload,
  type AgentSyncResponsePayload,
} from "@conclave/agent-protocol";
import type { AgentConfig } from "./config.js";
import { AgentLogger } from "./logger.js";

export interface CloudTransport {
  postMessage(
    message: AgentProtocolMessage,
    token?: string,
  ): Promise<AgentProtocolMessage | void>;
  enrollAgent(
    cloudUrl: string,
    enrollmentToken: string,
  ): Promise<{
    agentId: string;
    workspaceId: string;
    authToken: string;
  }>;
}

export class HttpCloudTransport implements CloudTransport {
  constructor(private readonly baseUrl: string) {}

  async enrollAgent(
    cloudUrl: string,
    enrollmentToken: string,
  ): Promise<{ agentId: string; workspaceId: string; authToken: string }> {
    const targetUrl = `${cloudUrl.replace(/\/+$/, "")}/api/v2/agents/enroll`;
    const response = await fetch(targetUrl, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
      },
      body: JSON.stringify({ token: enrollmentToken }),
    });

    if (!response.ok) {
      const errText = await response.text();
      throw new Error(
        `Enrollment failed with status ${response.status}: ${errText}`,
      );
    }

    const data = (await response.json()) as {
      agentId: string;
      workspaceId: string;
      authToken: string;
    };
    return data;
  }

  async postMessage(
    message: AgentProtocolMessage,
    token?: string,
  ): Promise<AgentProtocolMessage | void> {
    const serialized = serializeAgentMessage(message);
    const headers: Record<string, string> = {
      "Content-Type": "application/json",
    };
    if (token) {
      headers["Authorization"] = `Bearer ${token}`;
    }

    const url = `${this.baseUrl.replace(/\/+$/, "")}/api/v2/agent-protocol/messages`;
    const response = await fetch(url, {
      method: "POST",
      headers,
      body: serialized,
    });

    if (!response.ok) {
      const errText = await response.text();
      throw new Error(
        `Cloud protocol request failed (${message.type}): ${response.status} ${errText}`,
      );
    }

    const responseText = await response.text();
    if (!responseText.trim()) {
      return undefined;
    }

    const parsedJson = JSON.parse(responseText) as unknown;
    return parseAgentMessage(parsedJson);
  }
}

export class CloudClient {
  private readonly transport: CloudTransport;

  constructor(
    private readonly config: AgentConfig,
    private readonly logger: AgentLogger,
    transport?: CloudTransport,
  ) {
    this.transport = transport ?? new HttpCloudTransport(config.cloudUrl);
  }

  /**
   * Enrolls this agent with Conclave Cloud using an enrollment token.
   */
  async enroll(enrollmentToken: string): Promise<{
    agentId: string;
    workspaceId: string;
    authToken: string;
  }> {
    this.logger.info("Enrolling agent with Conclave Cloud", {
      cloudUrl: this.config.cloudUrl,
    });
    return this.transport.enrollAgent(this.config.cloudUrl, enrollmentToken);
  }

  /**
   * Helper to create a base envelope.
   */
  createBaseEnvelope<TType extends string, TPayload>(
    type: TType,
    payload: TPayload,
    correlationId?: string,
  ) {
    return {
      protocol: AGENT_PROTOCOL_NAME,
      protocolVersion: AGENT_PROTOCOL_VERSION,
      messageId: `msg-${Date.now()}-${Math.random().toString(36).slice(2, 9)}`,
      correlationId,
      timestamp: new Date().toISOString(),
      type,
      payload,
    };
  }

  /**
   * Sends agent.hello handshake to Cloud.
   */
  async sendHello(payload: AgentHelloPayload): Promise<AgentHelloAckPayload> {
    const envelope = this.createBaseEnvelope("agent.hello", payload);
    const validMessage = parseAgentMessage(envelope);
    const reply = await this.transport.postMessage(
      validMessage,
      this.config.agentToken,
    );

    if (!reply || reply.type !== "agent.hello.ack") {
      throw new Error(
        `Expected 'agent.hello.ack' from Cloud, received: ${reply ? reply.type : "empty response"}`,
      );
    }

    return reply.payload as AgentHelloAckPayload;
  }

  /**
   * Sends agent.heartbeat to Cloud.
   */
  async sendHeartbeat(
    payload: AgentHeartbeatPayload,
  ): Promise<AgentHeartbeatAckPayload> {
    const envelope = this.createBaseEnvelope("agent.heartbeat", payload);
    const validMessage = parseAgentMessage(envelope);
    const reply = await this.transport.postMessage(
      validMessage,
      this.config.agentToken,
    );

    if (!reply || reply.type !== "agent.heartbeat.ack") {
      throw new Error(
        `Expected 'agent.heartbeat.ack' from Cloud, received: ${reply ? reply.type : "empty response"}`,
      );
    }

    return reply.payload as AgentHeartbeatAckPayload;
  }

  /**
   * Sends agent.sync.request to Cloud.
   */
  async sendSync(
    payload: AgentSyncRequestPayload,
  ): Promise<AgentSyncResponsePayload> {
    const envelope = this.createBaseEnvelope("agent.sync.request", payload);
    const validMessage = parseAgentMessage(envelope);
    const reply = await this.transport.postMessage(
      validMessage,
      this.config.agentToken,
    );

    if (!reply || reply.type !== "agent.sync.response") {
      throw new Error(
        `Expected 'agent.sync.response' from Cloud, received: ${reply ? reply.type : "empty response"}`,
      );
    }

    return reply.payload as AgentSyncResponsePayload;
  }

  /**
   * Sends a general protocol message (such as assignment progress, result, status).
   */
  async sendMessage(
    message: AgentProtocolMessage,
  ): Promise<AgentProtocolMessage | void> {
    return this.transport.postMessage(message, this.config.agentToken);
  }
}
