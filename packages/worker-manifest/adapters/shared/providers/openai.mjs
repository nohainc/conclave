import { endpointFor, getJson, postJson } from "../api_protocol.mjs";

export async function validateCredential({ apiKey, config }) {
  const url = endpointFor(
    config.endpointUrl,
    "https://api.openai.com/v1",
    "models",
  );
  const headers = { authorization: `Bearer ${apiKey}` };
  if (config.projectId) headers["openai-project"] = config.projectId;
  if (config.organizationId)
    headers["openai-organization"] = config.organizationId;
  await getJson(url, headers, 15_000);
}

export async function generate({ apiKey, model, prompt, config }) {
  const url = endpointFor(
    config.endpointUrl,
    "https://api.openai.com/v1",
    "responses",
  );
  const headers = { authorization: `Bearer ${apiKey}` };
  if (config.projectId) headers["openai-project"] = config.projectId;
  if (config.organizationId)
    headers["openai-organization"] = config.organizationId;
  const response = await postJson(url, headers, { model, input: prompt });
  const output = Array.isArray(response.output)
    ? response.output
        .filter(
          (item) => item.type === "message" && Array.isArray(item.content),
        )
        .flatMap((item) => item.content)
        .filter(
          (part) =>
            part.type === "output_text" && typeof part.text === "string",
        )
        .map((part) => part.text)
        .join("")
    : "";
  if (!output.trim()) {
    throw new Error("OpenAI returned no text output.");
  }
  return output;
}
