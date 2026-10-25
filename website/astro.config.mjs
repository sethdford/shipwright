import { defineConfig } from "astro/config";
import starlight from "@astrojs/starlight";

// Expressive Code gives the copy button only a title. This sets an explicit aria-label,
// which screen readers announce before the title fallback.
const copyButtonLabel = {
  name: "copy-button-label",
  hooks: {
    postprocessRenderedBlock: ({ renderData }) => {
      labelCopyButtons(renderData.blockAst);
    },
  },
};

function labelCopyButtons(node) {
  if (node?.type === "element" && node.properties?.className?.includes("copy")) {
    for (const child of node.children) {
      if (child.type === "element" && child.tagName === "button") {
        child.properties.ariaLabel = "Copy code to clipboard";
      }
    }
  }
  for (const child of node?.children ?? []) labelCopyButtons(child);
}

export default defineConfig({
  site: "https://sethdford.github.io",
  base: "/shipwright",
  integrations: [
    starlight({
      components: {
        Footer: "./src/components/Footer.astro",
      },
      title: "Shipwright",
      description:
        "Orchestrate AI coding teams with autonomous agents, delivery pipelines, and DORA metrics.",
      logo: {
        light: "./src/assets/logo-light.svg",
        dark: "./src/assets/logo-dark.svg",
        replacesTitle: false,
      },
      social: {
        github: "https://github.com/sethdford/shipwright",
      },
      customCss: ["./src/styles/custom.css"],
      expressiveCode: { plugins: [copyButtonLabel] },
      sidebar: [
        {
          label: "Getting Started",
          items: [
            { label: "Quick Start", link: "/quick-start/" },
            { label: "Compare", link: "/compare/" },
          ],
        },
        {
          label: "Guides",
          items: [
            { label: "Delivery Pipeline", link: "/guides/pipeline/" },
            { label: "Autonomous Daemon", link: "/guides/daemon/" },
            { label: "Repo Preparation", link: "/guides/prep/" },
            { label: "Continuous Loop", link: "/guides/loop/" },
            { label: "Fleet Management", link: "/guides/fleet/" },
            { label: "Bulk Fix", link: "/guides/fix/" },
            { label: "Cost Intelligence", link: "/guides/cost/" },
            { label: "Dashboard", link: "/guides/dashboard/" },
            { label: "Issue Tracking", link: "/guides/tracking/" },
            { label: "Persistent Memory", link: "/guides/memory/" },
            { label: "Intelligence Layer", link: "/guides/intelligence/" },
            { label: "Code Factory", link: "/guides/code-factory/" },
          ],
        },
        {
          label: "Reference",
          items: [
            { label: "CLI Reference", link: "/reference/cli/" },
            { label: "Team Templates", link: "/reference/templates/" },
            { label: "Configuration", link: "/reference/configuration/" },
            { label: "Wave Patterns", link: "/reference/patterns/" },
            { label: "Advanced Features", link: "/reference/advanced/" },
          ],
        },
        {
          label: "Help",
          items: [
            { label: "Troubleshooting", link: "/troubleshooting/" },
            { label: "FAQ", link: "/faq/" },
          ],
        },
      ],
    }),
  ],
});
