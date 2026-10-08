// Match complete simple Dart/TS operands. Do not start inside a member access:
// navigator.context ?? context and page.cursor ?? cursor are valid fallbacks.
const atom = String.raw`(?:[A-Za-z_]\w*(?:\??\.[A-Za-z_]\w*)*(?:\[['"][A-Za-z_]\w*['"]\])?|['"][A-Za-z_][\w.-]*['"])`;
export function renameArtifacts(source) {
  const repeated = new RegExp(
    String.raw`(?<![\w.?])(${atom})\s*\?\?\s*\1(?![\w.\[])`,
    "g",
  );
  const comparisons =
    /(?<![\w.?])([A-Za-z_]\w*(?:\.[A-Za-z_]\w*)*(?:\[\d+\])?\s*==\s*['"][\w.-]+['"])\s*\|\|\s*\1/g;
  const literals = /(['"][\w.-]+['"])\s*\|\|\s*\1/g;
  return [
    ...source.matchAll(repeated),
    ...source.matchAll(comparisons),
    ...source.matchAll(literals),
  ].map((match) => ({
    line: source.slice(0, match.index).split("\n").length,
    expression: match[0],
  }));
}
