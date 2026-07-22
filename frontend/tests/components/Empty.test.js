import { describe, expect, it } from "vitest";

import Empty from "@/components/Empty";

describe("Empty", () => {
  it("can be imported without an unavailable utility module", () => {
    expect(Empty).toBeTypeOf("function");
  });
});
