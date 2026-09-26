import { generate as openai } from "./openai.mjs";
import { generate as gemini } from "./gemini.mjs";
import { generate as anthropic } from "./anthropic.mjs";

export const providers = {
  "openai-api": { displayName: "OpenAI", generate: openai },
  "gemini-api": { displayName: "Gemini", generate: gemini },
  "anthropic-api": { displayName: "Anthropic", generate: anthropic },
};
