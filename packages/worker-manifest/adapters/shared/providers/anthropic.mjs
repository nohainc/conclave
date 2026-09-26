import { endpointFor, getJson, postJson } from "../api_protocol.mjs";

export async function validateCredential({ apiKey, config }) {
  const url = endpointFor(
    config.endpointUrl,
    "https://api.anthropic.com",
    "v1/models",
  );
  const response = await getJson(
    url,
    {
      "x-api-key": apiKey,
      "anthropic-version": "2023-06-01",
    },
    15_000,
  );
  return (response.data ?? [])
    .map((model) => model.id)
    .filter((id) => typeof id === "string")
    .slice(0, 500);
}

export async function generate({ apiKey, model, prompt, config }) {
  const url = endpointFor(
    config.endpointUrl,
    "https://api.anthropic.com",
    "v1/messages",
  );
  const response = await postJson(
    url,
    {
      "x-api-key": apiKey,
      "anthropic-version": "2023-06-01",
    },
    {
      model,
      max_tokens: 4096,
      messages: [{ role: "user", content: prompt }],
    },
  );
  const output = Array.isArray(response.content)
    ? response.content
        .filter((part) => part.type === "text" && typeof part.text === "string")
        .map((part) => part.text)
        .join("")
    : "";
  if (!output.trim()) throw new Error("Anthropic returned no text output.");
  return output;
}
