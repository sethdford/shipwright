/** Architecture fitness rules F1–F4 (spec §3.3). Messages tell agents how to fix. */
module.exports = {
  forbidden: [
    {
      name: "F1-domain-is-pure",
      comment:
        "domain/ may import only its own domain and src/shared/kernel. Move I/O behind a port in application/.",
      severity: "error",
      from: { path: "^src/contexts/([^/]+)/domain/" },
      to: { path: "^src/", pathNot: ["^src/contexts/$1/domain/", "^src/shared/kernel/"] },
    },
    {
      name: "F1-domain-no-node-core",
      comment: "domain/ must not use Node/Bun built-ins. Depend on a port instead.",
      severity: "error",
      from: { path: "^src/contexts/[^/]+/domain/" },
      to: { dependencyTypes: ["core"] },
    },
    {
      name: "F1-kernel-is-pure",
      comment: "src/shared/kernel holds types and pure helpers only.",
      severity: "error",
      from: { path: "^src/shared/kernel/" },
      to: { path: "^src/", pathNot: "^src/shared/kernel/" },
    },
    {
      name: "F2-application-no-adapters",
      comment: "application/ depends on ports, never on adapters or cli. Inject the adapter from main.ts.",
      severity: "error",
      from: { path: "^src/contexts/[^/]+/application/" },
      to: { path: "^src/(adapters|cli)/" },
    },
    {
      name: "F3-contexts-via-index",
      comment: "Import another context only through src/contexts/<ctx>/index.ts.",
      severity: "error",
      from: { path: "^src/contexts/([^/]+)/" },
      to: { path: "^src/contexts/[^/]+/", pathNot: ["^src/contexts/$1/", "^src/contexts/[^/]+/index\\.ts$"] },
    },
    {
      name: "F3-outsiders-via-index",
      comment: "cli/ and main.ts import a context only through its index.ts.",
      severity: "error",
      from: { path: "^src/(cli/|main\\.ts)" },
      to: { path: "^src/contexts/[^/]+/.+", pathNot: "^src/contexts/[^/]+/index\\.ts$" },
    },
    {
      name: "F4-no-cycles",
      comment: "Break the cycle by extracting the shared piece into a port or the kernel.",
      severity: "error",
      from: {},
      to: { circular: true },
    },
  ],
  options: {
    doNotFollow: { path: "node_modules" },
    exclude: { path: "\\.test\\.ts$" },
    tsConfig: { fileName: "tsconfig.json" },
    tsPreCompilationDeps: true,
  },
};
