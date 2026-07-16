import { createElement } from "react";
import { renderToStaticMarkup } from "react-dom/server";
import { describe, expect, it } from "vitest";

import { SignDetectionResult } from "@/components/SignDetectionResult.jsx";

describe("SignDetectionResult", () => {
  it("renders annotated output and per-image errors", () => {
    const html = renderToStaticMarkup(
      createElement(SignDetectionResult, {
        data: {
          task_id: 7,
          results: [
            {
              filename: "road.jpg",
              success: true,
              annotated_image_url: "/uploads/detections/7/road.jpg",
              traffic_signs: [{ type: "pl60", confidence: 91 }],
            },
            {
              filename: "broken.jpg",
              success: false,
              error: "Unable to decode uploaded image",
              traffic_signs: [],
            },
          ],
        },
      })
    );

    expect(html).toContain("/uploads/detections/7/road.jpg");
    expect(html).toContain("road.jpg");
    expect(html).toContain("最高限速 60 km/h");
    expect(html).not.toContain(">pl60<");
    expect(html).toContain("91%");
    expect(html).toContain("broken.jpg");
    expect(html).toContain("Unable to decode uploaded image");
  });

  it("renders the classifier display label and recognition mode", () => {
    const html = renderToStaticMarkup(
      createElement(SignDetectionResult, {
        data: {
          task_id: 8,
          recognition_mode: "classify",
          results: [
            {
              filename: "00000.png",
              success: true,
              traffic_signs: [
                {
                  type: "Vehicles over 3.5 metric tons prohibited",
                  display_name: "禁止 3.5 吨以上车辆通行",
                  confidence: 97.5,
                },
              ],
            },
          ],
        },
      })
    );

    expect(html).toContain("classify");
    expect(html).toContain("禁止 3.5 吨以上车辆通行");
  });
});
