import { describe, expect, it, vi } from "vitest";
import {
  EmailDeliveryError,
  isPreAcceptanceSenderRejection,
  resolveEmailSenderConfig,
  sendConfiguredEmail,
} from "../src/email/email-config.js";

describe("centralized email sender configuration", () => {
  it("uses the Conclave primary and Vitalii fallback by default", () => {
    expect(resolveEmailSenderConfig({})).toEqual({
      primary: "conclave@nohainc.com",
      fallback: "vitalii@nohainc.com",
      displayName: "Conclave AX",
    });
  });

  it("accepts overrides and normalizes sender addresses", () => {
    expect(
      resolveEmailSenderConfig({
        CONCLAVE_EMAIL_FROM: "Primary@Example.com ",
        CONCLAVE_EMAIL_FALLBACK_FROM: "fallback@example.com",
        CONCLAVE_EMAIL_FROM_NAME: " Conclave Test ",
      }),
    ).toEqual({
      primary: "primary@example.com",
      fallback: "fallback@example.com",
      displayName: "Conclave Test",
    });
  });

  it.each([
    ["CONCLAVE_EMAIL_FROM", { CONCLAVE_EMAIL_FROM: "invalid" }],
    [
      "CONCLAVE_EMAIL_FALLBACK_FROM",
      { CONCLAVE_EMAIL_FALLBACK_FROM: "invalid" },
    ],
    ["CONCLAVE_EMAIL_FROM", { CONCLAVE_EMAIL_FROM: "auth@auth.earthuc.com" }],
    [
      "CONCLAVE_EMAIL_FALLBACK_FROM",
      { CONCLAVE_EMAIL_FALLBACK_FROM: "auth@auth.earthuc.com" },
    ],
  ])("rejects invalid %s values", (_field, env) => {
    expect(() => resolveEmailSenderConfig(env)).toThrow();
  });

  it("rejects identical primary and fallback addresses", () => {
    expect(() =>
      resolveEmailSenderConfig({
        CONCLAVE_EMAIL_FROM: "same@example.com",
        CONCLAVE_EMAIL_FALLBACK_FROM: "SAME@example.com",
      }),
    ).toThrow("must differ");
  });

  it("uses the primary sender and consistent display name", async () => {
    const send = vi.fn(async () => ({ messageId: "message-1" }));
    await expect(
      sendConfiguredEmail(
        { CONCLAVE_EMAIL: { send } },
        { to: "person@example.com", subject: "Subject", text: "Body" },
      ),
    ).resolves.toEqual({
      status: "accepted",
      sender: "conclave@nohainc.com",
      usedFallback: false,
      messageId: "message-1",
    });
    expect(send).toHaveBeenCalledWith({
      to: "person@example.com",
      from: { email: "conclave@nohainc.com", name: "Conclave AX" },
      subject: "Subject",
      text: "Body",
    });
  });

  it("uses fallback only for an explicit pre-acceptance sender rejection", async () => {
    const send = vi
      .fn()
      .mockRejectedValueOnce({ code: "E_SENDER_NOT_VERIFIED" })
      .mockResolvedValueOnce({ messageId: "message-2" });
    await expect(
      sendConfiguredEmail(
        { CONCLAVE_EMAIL: { send } },
        { to: "person@example.com", subject: "Subject" },
      ),
    ).resolves.toEqual({
      status: "accepted",
      sender: "vitalii@nohainc.com",
      usedFallback: true,
      messageId: "message-2",
    });
    expect(send).toHaveBeenNthCalledWith(2, {
      to: "person@example.com",
      from: { email: "vitalii@nohainc.com", name: "Conclave AX" },
      subject: "Subject",
    });
  });

  it("does not retry transport or recipient failures", async () => {
    const error = new Error("delivery timeout");
    const send = vi.fn().mockRejectedValue(error);
    await expect(
      sendConfiguredEmail(
        { CONCLAVE_EMAIL: { send } },
        { to: "person@example.com", subject: "Subject" },
      ),
    ).rejects.toMatchObject({
      name: "EmailDeliveryError",
      status: "temporary_failure",
      cause: error,
    });
    expect(send).toHaveBeenCalledOnce();
  });

  it.each([
    ["recipient_rejected", { code: "E_RECIPIENT_NOT_ALLOWED" }],
    ["rate_limited", { code: "E_RATE_LIMIT_EXCEEDED" }],
    ["service_unavailable", { status: 503 }],
  ])("classifies provider evidence as %s", async (status, providerError) => {
    const send = vi.fn().mockRejectedValue(providerError);
    await expect(
      sendConfiguredEmail(
        { CONCLAVE_EMAIL: { send } },
        { to: "person@example.com", subject: "Subject" },
      ),
    ).rejects.toMatchObject({ status });
    expect(send).toHaveBeenCalledOnce();
  });

  it("classifies missing binding and invalid sender configuration", async () => {
    await expect(
      sendConfiguredEmail({}, { to: "person@example.com", subject: "Subject" }),
    ).rejects.toMatchObject({ status: "configuration_error" });
    const send = vi.fn();
    await expect(
      sendConfiguredEmail(
        { CONCLAVE_EMAIL: { send }, CONCLAVE_EMAIL_FROM: "invalid" },
        { to: "person@example.com", subject: "Subject" },
      ),
    ).rejects.toMatchObject({ status: "configuration_error" });
    expect(send).not.toHaveBeenCalled();
  });

  it("reports an unauthorized fallback sender without retrying again", async () => {
    const send = vi
      .fn()
      .mockRejectedValueOnce({ code: "E_SENDER_NOT_VERIFIED" })
      .mockRejectedValueOnce({ code: "E_SENDER_DOMAIN_NOT_AVAILABLE" });
    await expect(
      sendConfiguredEmail(
        { CONCLAVE_EMAIL: { send } },
        { to: "person@example.com", subject: "Subject" },
      ),
    ).rejects.toMatchObject({ status: "sender_not_authorized" });
    expect(send).toHaveBeenCalledTimes(2);
  });

  it("reports both senders unavailable without a third attempt", async () => {
    const send = vi
      .fn()
      .mockRejectedValueOnce({ code: "E_SENDER_NOT_VERIFIED" })
      .mockRejectedValueOnce({ code: "E_SENDER_DOMAIN_NOT_AVAILABLE" });
    await expect(
      sendConfiguredEmail(
        { CONCLAVE_EMAIL: { send } },
        { to: "person@example.com", subject: "Subject" },
      ),
    ).rejects.toMatchObject({
      name: "EmailDeliveryError",
      status: "sender_not_authorized",
      providerCode: "e_sender_domain_not_available",
    });
    expect(send).toHaveBeenCalledTimes(2);
  });

  it("exposes the common error model as an EmailDeliveryError", async () => {
    const send = vi.fn().mockRejectedValue({ code: "recipient_rejected" });
    await expect(
      sendConfiguredEmail(
        { CONCLAVE_EMAIL: { send } },
        { to: "person@example.com", subject: "Subject" },
      ),
    ).rejects.toBeInstanceOf(EmailDeliveryError);
  });

  it("never classifies accepted or unknown errors as safe fallback cases", () => {
    expect(
      isPreAcceptanceSenderRejection({ code: "sender_not_verified" }),
    ).toBe(true);
    expect(
      isPreAcceptanceSenderRejection({
        code: "sender_not_verified",
        accepted: true,
      }),
    ).toBe(false);
    expect(isPreAcceptanceSenderRejection(new Error("timeout"))).toBe(false);
  });

  it.each(["", "not-an-email", "person@example.com\nBcc:evil@example.com"])(
    "rejects invalid recipients before provider submission: %s",
    async (to) => {
      const send = vi.fn();
      await expect(
        sendConfiguredEmail(
          { CONCLAVE_EMAIL: { send } },
          { to, subject: "Subject" },
        ),
      ).rejects.toMatchObject({ status: "recipient_rejected" });
      expect(send).not.toHaveBeenCalled();
    },
  );
});
