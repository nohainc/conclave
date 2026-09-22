import { describe, expect, it } from "vitest";
import {
  estimatedSelectionCost,
  resolveQuality,
  routeWorkers,
} from "../src/index.js";
import { worker } from "./assignment-fixtures.js";

describe("quality routing", () => {
  it("routes available Workers by cost and independence", () => {
    const selection = routeWorkers(
      [
        worker("cheap", { cost: 100 }).worker,
        worker("expensive", { cost: 200 }).worker,
      ],
      { capability: "planning" },
      resolveQuality("balanced"),
    );
    expect(selection.map((item) => item.id)).toEqual(["cheap", "expensive"]);
    expect(estimatedSelectionCost(selection)).toBe(300);
  });
  it("rejects a custom policy with an invalid parallel limit", () => {
    expect(() =>
      resolveQuality("custom", { candidateCount: 1, maxParallel: 2 }),
    ).toThrow(/maxParallel/);
  });
});
