import fs from "node:fs";
import path from "node:path";
import type { AgentJournalEntry } from "@conclave/agent-protocol";
import type { AgentConfig } from "./config.js";

export class AgentJournal {
  private readonly journalPath: string;
  private readonly entries = new Map<string, AgentJournalEntry>();

  constructor(private readonly config: AgentConfig) {
    this.journalPath = path.join(
      this.config.journalDir,
      "assignment-journal.json",
    );
  }

  /**
   * Loads journal entries from disk.
   */
  load(): readonly AgentJournalEntry[] {
    this.entries.clear();
    if (!fs.existsSync(this.journalPath)) {
      return [];
    }

    try {
      const content = fs.readFileSync(this.journalPath, "utf8");
      const parsed = JSON.parse(content) as unknown;
      if (Array.isArray(parsed)) {
        for (const item of parsed) {
          if (
            typeof item === "object" &&
            item !== null &&
            typeof item.assignmentId === "string" &&
            typeof item.attemptId === "string" &&
            typeof item.idempotencyKey === "string" &&
            typeof item.status === "string"
          ) {
            this.entries.set(item.assignmentId, item as AgentJournalEntry);
          }
        }
      }
    } catch {
      // In case of corrupt file, keep current memory map and do not crash
    }

    return this.list();
  }

  /**
   * Persists the current state of journal entries to disk atomically.
   */
  private flush(): void {
    fs.mkdirSync(this.config.journalDir, { recursive: true });
    const tempPath = `${this.journalPath}.tmp.${Date.now()}`;
    const payload = JSON.stringify([...this.entries.values()], null, 2);
    fs.writeFileSync(tempPath, payload, "utf8");
    fs.renameSync(tempPath, this.journalPath);
  }

  /**
   * Records the start of an assignment execution.
   */
  recordStart(
    assignmentId: string,
    attemptId: string,
    idempotencyKey: string,
  ): AgentJournalEntry {
    const entry: AgentJournalEntry = {
      assignmentId,
      attemptId,
      idempotencyKey,
      status: "running",
      updatedAt: new Date().toISOString(),
    };
    this.entries.set(assignmentId, entry);
    this.flush();
    return entry;
  }

  /**
   * Records assignment completion or failure with terminal results.
   */
  recordResult(
    assignmentId: string,
    terminalResult: Record<string, unknown>,
    status: "completed" | "failed" | "cancelled" = "completed",
  ): AgentJournalEntry {
    const existing = this.entries.get(assignmentId);
    const entry: AgentJournalEntry = {
      assignmentId,
      attemptId: existing?.attemptId ?? assignmentId,
      idempotencyKey: existing?.idempotencyKey ?? assignmentId,
      status,
      terminalResult,
      updatedAt: new Date().toISOString(),
    };
    this.entries.set(assignmentId, entry);
    this.flush();
    return entry;
  }

  /**
   * Retrieves an entry by assignment ID.
   */
  get(assignmentId: string): AgentJournalEntry | undefined {
    return this.entries.get(assignmentId);
  }

  /**
   * Lists all current journal entries.
   */
  list(): readonly AgentJournalEntry[] {
    return [...this.entries.values()];
  }

  /**
   * Returns all unreconciled terminal entries (i.e. completed/failed/cancelled assignments waiting for Cloud sync).
   */
  getUnreconciled(): readonly AgentJournalEntry[] {
    return [...this.entries.values()].filter(
      (entry) =>
        entry.status === "completed" ||
        entry.status === "failed" ||
        entry.status === "cancelled",
    );
  }

  /**
   * Acknowledges that Cloud has recorded the terminal result, allowing entry removal from journal.
   */
  acknowledge(assignmentId: string): void {
    if (this.entries.delete(assignmentId)) {
      this.flush();
    }
  }

  /**
   * Removes an assignment entry.
   */
  remove(assignmentId: string): void {
    if (this.entries.delete(assignmentId)) {
      this.flush();
    }
  }

  /**
   * Clears the entire journal.
   */
  clear(): void {
    this.entries.clear();
    if (fs.existsSync(this.journalPath)) {
      try {
        fs.unlinkSync(this.journalPath);
      } catch {
        // ignore deletion errors
      }
    }
  }
}
