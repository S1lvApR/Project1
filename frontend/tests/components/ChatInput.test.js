import { describe, expect, it } from "vitest";

describe("ChatInput component", () => {
  it("can be imported", async () => {
    const module = await import("@/components/ChatInput.jsx");
    expect(module.ChatInput).toBeDefined();
  });
});
