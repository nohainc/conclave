import { endpointFor, getJson, postJson } from "../api_protocol.mjs";

export async function validateCredential({ apiKey, config }) {
  const base =
    config.endpointUrl ?? "https://generativelanguage.googleapis.com/v1beta";
  const url = endpointFor(base, base, "models");
  const response = await getJson(url, { "x-goog-api-key": apiKey }, 15_000);
  return (response.models ?? [])
    .filter(
      (model) =>
        Array.isArray(model.supportedGenerationMethods) &&
        model.supportedGenerationMethods.includes("generateContent"),
    )
    .map((model) => String(model.name ?? "").replace(/^models\//, ""))
    .filter(Boolean)
    .slice(0, 500);
}

export async function generate({ apiKey, model, prompt, config }) {
  const base =
    config.endpointUrl ?? "https://generativelanguage.googleapis.com/v1beta";
  const url = endpointFor(
    base,
    base,
    `models/${encodeURIComponent(model)}:generateContent`,
  );
  const response = await postJson(
    url,
    { "x-goog-api-key": apiKey },
    {
      contents: [{ parts: [{ text: prompt }] }],
    },
  );
  const parts = response.candidates?.[0]?.content?.parts;
  const output = Array.isArray(parts)
    ? parts
        .filter((part) => typeof part.text === "string")
        .map((part) => part.text)
        .join("")
    : "";
  if (!output.trim()) throw new Error("Gemini returned no text output.");
  return output;
}
