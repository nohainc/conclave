import { execFile, execFileSync } from "node:child_process";
import { promisify } from "node:util";

const execFileAsync = promisify(execFile);

export interface CredentialStore {
  get(account: string): Promise<string | undefined>;
  set(account: string, secret: string): Promise<void>;
  delete(account: string): Promise<void>;
}

export class MemoryCredentialStore implements CredentialStore {
  private readonly values = new Map<string, string>();

  async get(account: string): Promise<string | undefined> {
    return this.values.get(account);
  }

  async set(account: string, secret: string): Promise<void> {
    this.values.set(account, secret);
  }

  async delete(account: string): Promise<void> {
    this.values.delete(account);
  }
}

/** macOS Keychain-backed storage. The secret never enters the agent config file. */
export class MacOSKeychainCredentialStore implements CredentialStore {
  constructor(private readonly service = "com.conclaveax.agent") {}

  private assertMacOS(): void {
    if (process.platform !== "darwin") {
      throw new Error("The macOS Keychain credential store requires macOS");
    }
  }

  async get(account: string): Promise<string | undefined> {
    this.assertMacOS();
    try {
      const result = await execFileAsync("security", [
        "find-generic-password",
        "-a",
        account,
        "-s",
        this.service,
        "-w",
      ]);
      return result.stdout.trim() || undefined;
    } catch {
      return undefined;
    }
  }

  async set(account: string, secret: string): Promise<void> {
    this.assertMacOS();
    await this.delete(account).catch(() => undefined);
    await execFileAsync("security", [
      "add-generic-password",
      "-a",
      account,
      "-s",
      this.service,
      "-w",
      secret,
      "-U",
    ]);
  }

  async delete(account: string): Promise<void> {
    this.assertMacOS();
    await execFileAsync("security", [
      "delete-generic-password",
      "-a",
      account,
      "-s",
      this.service,
    ]);
  }
}

export function readMacOSCredentialSync(
  account: string,
  service = "com.conclaveax.agent",
): string | undefined {
  if (process.platform !== "darwin") return undefined;
  try {
    return (
      execFileSync(
        "security",
        ["find-generic-password", "-a", account, "-s", service, "-w"],
        { encoding: "utf8" },
      ).trim() || undefined
    );
  } catch {
    return undefined;
  }
}

export function createCredentialStore(): CredentialStore {
  if (process.platform === "darwin") return new MacOSKeychainCredentialStore();
  throw new Error(
    `Secure credentials are not implemented for ${process.platform}; use the platform installer when it is available`,
  );
}
