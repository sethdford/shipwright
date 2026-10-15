/** Architecture fitness rules F1–F4 (spec §3.3). Messages tell agents how to fix. */
module.exports = {
  forbidden: [
    {
      name: "F1-domain-is-pure",
      comment:
        "F1: domain/ may import only its own domain and src/shared/kernel. Move I/O behind a port in application/.",
      severity: "error",
      from: { path: "^src/contexts/([^/]+)/domain/" },
      to: { path: "^src/", pathNot: ["^src/contexts/$1/domain/", "^src/shared/kernel/"] },
    },
    {
      name: "F1-domain-no-node-core",
      comment: "F1: domain/ must not use Node/Bun built-ins. Depend on a port instead.",
      severity: "error",
      from: { path: "^src/contexts/[^/]+/domain/" },
      to: { dependencyTypes: ["core"] },
    },
    {
      name: "F1-kernel-is-pure",
      comment: "F1: src/shared/kernel holds types and pure helpers only. Move anything else into a context or an adapter.",
      severity: "error",
      from: { path: "^src/shared/kernel/" },
      to: { path: "^src/", pathNot: "^src/shared/kernel/" },
    },
    {
      name: "F2-application-no-adapters",
      comment: "F2: application/ depends on ports, never on adapters or cli. Inject the adapter from main.ts.",
      severity: "error",
      from: { path: "^src/contexts/[^/]+/application/" },
      to: { path: "^src/(adapters|cli)/" },
    },
    {
      name: "F3-contexts-via-index",
      comment: "F3: import another context only through src/contexts/<ctx>/index.ts; add what you need to its exports.",
      severity: "error",
      from: { path: "^src/contexts/([^/]+)/" },
      to: { path: "^src/contexts/[^/]+/", pathNot: ["^src/contexts/$1/", "^src/contexts/[^/]+/index\\.ts$"] },
    },
    {
      name: "F3-outsiders-via-index",
      comment:
        "F3: every file outside src/contexts (cli, main.ts, adapters, testing, ...) imports a context only through its index.ts; add what you need to its exports.",
      severity: "error",
      from: { path: "^src/", pathNot: "^src/contexts/" },
      to: { path: "^src/contexts/[^/]+/.+", pathNot: "^src/contexts/[^/]+/index\\.ts$" },
    },
    {
      name: "F3-no-test-fakes-in-production",
      comment: "F3: production code must not import src/testing; inject fakes only from tests.",
      severity: "error",
      from: { path: "^src/", pathNot: "^src/testing/" },
      to: { path: "^src/testing/" },
    },
    {
      name: "F3-src-not-dashboard",
      comment:
        "F3: src/ never imports dashboard/ (a separate project until Wave 3). Port the piece you need into a context.",
      severity: "error",
      from: { path: "^src/" },
      to: { path: "^dashboard/" },
    },
    {
      name: "F4-no-cycles",
      comment: "F4: break the cycle by moving the shared piece into a port or the kernel.",
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
