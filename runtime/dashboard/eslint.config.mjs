import { defineConfig, globalIgnores } from "eslint/config";
import nextVitals from "eslint-config-next/core-web-vitals";
import nextTs from "eslint-config-next/typescript";

const eslintConfig = defineConfig([
  ...nextVitals,
  ...nextTs,
  // Override default ignores of eslint-config-next.
  globalIgnores([
    // Default ignores of eslint-config-next:
    ".next/**",
    "out/**",
    "build/**",
    "next-env.d.ts",
  ]),
  // Five pre-existing violations, tracked in issue #123. Scoped to exactly these
  // paths so the rule stays blocking for every other file, including new code.
  // Fix the components and delete this block; do not widen it to a directory, and
  // do not put continue-on-error back on the Lint job.
  {
    files: [
      "app/page.tsx",
      "app/logs/page.tsx",
      "app/components/RetroActivityMonitor.tsx",
      "app/connectivity/components/NetworkList.tsx",
      "app/connectivity/components/SavedNetworksList.tsx",
    ],
    rules: {
      "react-hooks/set-state-in-effect": "warn",
    },
  },
]);

export default eslintConfig;
