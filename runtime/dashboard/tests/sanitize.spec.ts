import { test, expect } from "@playwright/test";
import fs from "node:fs";
import path from "node:path";

// Walk app/ for directories containing page.tsx, convert each to a URL path.
// Skips:
//   - api/ directories (API routes, no rendered HTML)
//   - directories starting with _ (Next App Router private folders)
// Route groups: (name) folders are transparent — they do not add a URL segment.
// Dynamic segments: [param] folders get a synthetic "test" value so the route
// is visitable. No dynamic segments exist in the dashboard today, but this
// prevents silent route-skipping if one is added later.
function enumerateRoutes(appDir: string): string[] {
  const routes: string[] = [];

  function walk(dir: string, urlSegments: string[]) {
    for (const entry of fs.readdirSync(dir)) {
      const full = path.join(dir, entry);
      if (!fs.statSync(full).isDirectory()) continue;
      if (entry === "api" || entry.startsWith("_")) continue;

      let nextSegments: string[];
      if (entry.startsWith("(") && entry.endsWith(")")) {
        // Route group — transparent to URL
        nextSegments = urlSegments;
      } else if (entry.startsWith("[") && entry.endsWith("]")) {
        // Dynamic segment — substitute synthetic placeholder
        nextSegments = [...urlSegments, "test"];
      } else {
        nextSegments = [...urlSegments, entry];
      }

      try {
        fs.statSync(path.join(full, "page.tsx"));
        routes.push("/" + nextSegments.join("/"));
      } catch {
        // no page.tsx in this directory — keep walking
      }

      walk(full, nextSegments);
    }
  }

  // Root page.tsx → '/'
  try {
    fs.statSync(path.join(appDir, "page.tsx"));
    routes.push("/");
  } catch {
    // no root page.tsx
  }

  walk(appDir, []);
  return [...new Set(routes)];
}

const APP_DIR = path.join(__dirname, "..", "app");
const ROUTES = enumerateRoutes(APP_DIR);

// Mirrors scripts/sanitize/banlist.txt — canonical source is that file.
// Any addition to banlist.txt MUST be mirrored here until a future refactor
// unifies them into a single source of truth.
const BANLIST = [
  "focal55",
  "arlowe-1",
  "casa_ybarra_chelsea",
  "/home/focal55",
  "joe@focal55",
  "iol-monorepo",
];

test.describe("sanitization: no founder literals in rendered HTML", () => {
  for (const route of ROUTES) {
    test(`route ${route} contains no banned literal`, async ({ page }) => {
      await page.goto(route, { waitUntil: "load" });
      // waitForTimeout instead of networkidle: networkidle is flaky against an
      // unconfigured backend (API routes return errors, never fully settle).
      // A short fixed wait lets useEffect-driven fetches resolve so second-render
      // content is included. Error states are valid render targets per CONTEXT.md.
      await page.waitForTimeout(1500);
      const html = (await page.content()).toLowerCase();
      for (const literal of BANLIST) {
        expect(
          html.includes(literal.toLowerCase()),
          `route ${route} rendered HTML contains banned literal "${literal}" — search /api response shapes and config defaults`,
        ).toBe(false);
      }
    });
  }
});
