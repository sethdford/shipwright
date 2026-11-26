import { expect, test } from "bun:test";
import { detectApp, packageRunner, portArgs, type RepoFacts } from "./detect";

const facts = (over: Partial<RepoFacts>): RepoFacts => ({
  packageJson: null,
  markers: [],
  cargoToml: null,
  goMains: [],
  ...over,
});
const pkg = (value: object) => JSON.stringify(value);

test("a Next.js app with a dev script is a web app run by its lockfile's runner", () => {
  const p = detectApp(
    facts({
      packageJson: pkg({ scripts: { dev: "next dev" }, dependencies: { next: "15" } }),
      markers: ["pnpm-lock.yaml"],
    }),
  );
  expect(p.web).toEqual({ framework: "next", start: ["pnpm", "run", "dev"], defaultPort: 3000 });
  expect(p.cli).toBeNull();
});

test("framework order: SvelteKit wins over the vite it depends on", () => {
  const p = detectApp(
    facts({
      packageJson: pkg({
        scripts: { dev: "vite dev" },
        devDependencies: { vite: "5", "@sveltejs/kit": "2" },
      }),
    }),
  );
  expect(p.web?.framework).toBe("sveltekit");
  expect(p.web?.start).toEqual(["npm", "run", "dev"]);
});

test("a package with only a build script is not a web app", () => {
  expect(detectApp(facts({ packageJson: pkg({ scripts: { build: "tsc" } }) })).web).toBeNull();
  expect(detectApp(facts({ packageJson: pkg({ scripts: { preview: "x" } }) })).web).toBeNull();
});

test("package.json bin is a CLI; unsafe names and paths are ignored", () => {
  const cli = detectApp(
    facts({ packageJson: pkg({ bin: { todo: "bin/todo.js" } }), markers: ["bun.lock"] }),
  ).cli;
  expect(cli).toEqual({ name: "todo", argv: ["bun", "bin/todo.js"] });
  const scoped = detectApp(facts({ packageJson: pkg({ name: "@me/tool", bin: "./cli.js" }) })).cli;
  expect(scoped).toEqual({ name: "tool", argv: ["node", "./cli.js"] });
  expect(detectApp(facts({ packageJson: pkg({ bin: { sw: "scripts/sw" } }) })).cli?.argv).toEqual([
    "./scripts/sw",
  ]);
  expect(detectApp(facts({ packageJson: pkg({ bin: { t: "src/cli.ts" } }) })).cli?.argv).toEqual([
    "bun",
    "src/cli.ts",
  ]);
  expect(detectApp(facts({ packageJson: pkg({ bin: { x: "$(rm -rf /)" } }) })).cli).toBeNull();
  expect(detectApp(facts({ packageJson: pkg({ bin: { x: "/etc/passwd" } }) })).cli).toBeNull();
});

test("Cargo and Go mains are CLIs; a library crate is not", () => {
  expect(detectApp(facts({ cargoToml: '[package]\nname = "rg"\n' })).cli?.argv).toEqual([
    "cargo",
    "run",
    "--quiet",
    "--",
  ]);
  expect(detectApp(facts({ cargoToml: '[package]\nname = "lib"\n[lib]\n' })).cli).toBeNull();
  expect(detectApp(facts({ goMains: ["server"] })).cli).toEqual({
    name: "server",
    argv: ["go", "run", "./cmd/server"],
  });
  expect(detectApp(facts({ goMains: ["server", "."] })).cli?.argv).toEqual(["go", "run", "."]);
});

test("malformed package.json detects nothing", () => {
  expect(detectApp(facts({ packageJson: "{" }))).toEqual({ web: null, cli: null });
});

test("runners and port flags", () => {
  expect(packageRunner(["yarn.lock"])).toEqual(["yarn", "run"]);
  expect(packageRunner([])).toEqual(["npm", "run"]);
  expect(portArgs("next", 4000)).toEqual(["-p", "4000"]);
  expect(portArgs("vite", 4000)).toEqual(["--port", "4000", "--host", "127.0.0.1"]);
  expect(portArgs("other", 4000)).toEqual([]);
});
