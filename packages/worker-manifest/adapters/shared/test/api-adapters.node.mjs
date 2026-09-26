import assert from "node:assert/strict";
import { test } from "node:test";
import {
  generate as openai,
  validateCredential as validateOpenAI,
} from "../providers/openai.mjs";
import {
  generate as gemini,
  validateCredential as validateGemini,
} from "../providers/gemini.mjs";
import {
  generate as anthropic,
  validateCredential as validateAnthropic,
} from "../providers/anthropic.mjs";
import { endpointFor } from "../api_protocol.mjs";

const endpoint = "http://127.0.0.1:9876";

function mockFetch(status, body) {
  let request;
  const previous = globalThis.fetch;
  globalThis.fetch = async (url, init) => {
    request = {
      url: new URL(url),
      ...init,
      headers: new Headers(init.headers),
    };
    return new Response(JSON.stringify(body), {
      status,
      headers: { "content-type": "application/json" },
    });
  };
  return {
    request: () => request,
    restore: () => {
      globalThis.fetch = previous;
    },
  };
}

test("OpenAI adapter sends Responses API request and returns normalized text", async () => {
  const mock = mockFetch(200, {
    output: [
      {
        type: "message",
        content: [{ type: "output_text", text: "OpenAI result" }],
      },
    ],
  });
  try {
    assert.equal(
      await openai({
        apiKey: "local-openai-key",
        model: "gpt-test",
        prompt: "work prompt",
        config: { endpointUrl: `${endpoint}/v1` },
      }),
      "OpenAI result",
    );
    const request = mock.request();
    assert.equal(request.url.pathname, "/v1/responses");
    assert.equal(
      request.headers.get("authorization"),
      "Bearer local-openai-key",
    );
    assert.deepEqual(JSON.parse(request.body), {
      model: "gpt-test",
      input: "work prompt",
    });
  } finally {
    mock.restore();
  }
});

test("Gemini adapter sends API key in a header and normalizes candidate text", async () => {
  const mock = mockFetch(200, {
    candidates: [{ content: { parts: [{ text: "Gemini result" }] } }],
  });
  try {
    assert.equal(
      await gemini({
        apiKey: "local-gemini-key",
        model: "gemini-test",
        prompt: "work prompt",
        config: { endpointUrl: `${endpoint}/v1beta` },
      }),
      "Gemini result",
    );
    const request = mock.request();
    assert.equal(
      request.url.pathname,
      "/v1beta/models/gemini-test:generateContent",
    );
    assert.equal(request.headers.get("x-goog-api-key"), "local-gemini-key");
    assert.equal(
      JSON.parse(request.body).contents[0].parts[0].text,
      "work prompt",
    );
  } finally {
    mock.restore();
  }
});

test("Anthropic adapter sends Messages API request and normalizes text blocks", async () => {
  const mock = mockFetch(200, {
    content: [{ type: "text", text: "Anthropic result" }],
  });
  try {
    assert.equal(
      await anthropic({
        apiKey: "local-anthropic-key",
        model: "claude-test",
        prompt: "work prompt",
        config: { endpointUrl: endpoint },
      }),
      "Anthropic result",
    );
    const request = mock.request();
    assert.equal(request.url.pathname, "/v1/messages");
    assert.equal(request.headers.get("x-api-key"), "local-anthropic-key");
    assert.equal(request.headers.get("anthropic-version"), "2023-06-01");
    assert.deepEqual(JSON.parse(request.body).messages, [
      { role: "user", content: "work prompt" },
    ]);
  } finally {
    mock.restore();
  }
});

test("provider failures do not leak response bodies or local credentials", async () => {
  const mock = mockFetch(401, { error: "private provider diagnostic" });
  try {
    await assert.rejects(
      openai({
        apiKey: "secret-that-must-not-leak",
        model: "gpt-test",
        prompt: "work prompt",
        config: { endpointUrl: endpoint },
      }),
      (error) => {
        assert.match(error.message, /authentication failed/i);
        assert.doesNotMatch(
          error.message,
          /private provider diagnostic|secret-that-must-not-leak/,
        );
        return true;
      },
    );
  } finally {
    mock.restore();
  }
});

test("API key validation uses provider model-list endpoints without generating content", async () => {
  const providers = [
    [validateOpenAI, `${endpoint}/v1`, "authorization", "openai-key"],
    [validateGemini, `${endpoint}/v1beta`, "x-goog-api-key", "gemini-key"],
    [validateAnthropic, endpoint, "x-api-key", "anthropic-key"],
  ];
  for (const [validate, endpointUrl, header, key] of providers) {
    const mock = mockFetch(200, { data: [] });
    try {
      await validate({ apiKey: key, config: { endpointUrl } });
      const request = mock.request();
      assert.equal(request.method, "GET");
      assert.equal(
        request.headers.get(header),
        header === "authorization" ? `Bearer ${key}` : key,
      );
      assert.equal(request.body, undefined);
      const expectedPath =
        validate === validateOpenAI
          ? "/v1/models"
          : validate === validateGemini
            ? "/v1beta/models"
            : "/v1/models";
      assert.equal(request.url.pathname, expectedPath);
    } finally {
      mock.restore();
    }
  }
});

test("custom endpoints reject cleartext remote transport and embedded credentials", () => {
  assert.throws(
    () => endpointFor("http://api.example.test", "https://default.test", "v1"),
    /HTTPS/,
  );
  assert.throws(
    () =>
      endpointFor(
        "https://user:pass@api.example.test",
        "https://default.test",
        "v1",
      ),
    /HTTPS/,
  );
  assert.doesNotThrow(() =>
    endpointFor("http://127.0.0.1:1234", "https://default.test", "v1"),
  );
});
