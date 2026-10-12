/** Resolve the repository's `.js` TypeScript import style for local tooling. */
export async function resolve(specifier, context, nextResolve) {
  try {
    return await nextResolve(specifier, context);
  } catch (error) {
    if (specifier.endsWith(".js")) {
      try {
        return await nextResolve(`${specifier.slice(0, -3)}.ts`, context);
      } catch {
        // Preserve Node's original resolution error when no TypeScript sibling exists.
      }
    }
    throw error;
  }
}
