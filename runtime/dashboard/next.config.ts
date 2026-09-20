import path from "node:path";
import type { NextConfig } from "next";

const nextConfig: NextConfig = {
  // The device runs `node server.js` under arlowe-dashboard.service. Without
  // `standalone`, `next build` emits no server.js at all and that unit's
  // ExecStart target can never exist — which is precisely the state the image
  // shipped in before Phase 7.1.
  output: "standalone",

  // Pin the tracing root to this directory rather than letting Next infer it.
  // Inference walks upward looking for a lockfile, so the standalone entry point
  // lands at a nesting depth that depends on what happens to sit ABOVE the
  // project — different in a dev checkout (runtime/dashboard inside the repo)
  // than in the image (/opt/arlowe/runtime/dashboard). Pinning it makes the
  // relocation step in build-venvs' sibling, build-dashboard.sh, deterministic
  // instead of dependent on the build host's directory layout.
  outputFileTracingRoot: path.join(__dirname),
};

export default nextConfig;
