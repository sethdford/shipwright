import { defineConfig } from "vitest/config";

export default defineConfig({
  test: {
    environment: "happy-dom",
    root: "./dashboard",
    include: ["src/**/*.test.ts", "services/**/*.test.ts", "routes/**/*.test.ts"],
    globals: true,
    coverage: {
      provider: "v8",
      reporter: ["text", "json-summary"],
      include: ["src/**/*.ts"],
      exclude: [
        "src/**/*.test.ts",
        "src/types/**",
        "src/views/**",
        "src/canvas/**",
        "src/components/header.ts",
        "src/components/modal.ts",
        "src/components/terminal.ts",
        "src/main.ts",
      ],
      thresholds: {
        statements: 70,
        branches: 60,
        functions: 70,
        lines: 70,
      },
    },
  },
  resolve: {
    alias: {
      "@": "./dashboard/src",
    },
  },
});
