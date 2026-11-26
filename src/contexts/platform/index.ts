export {
  type HydrateOptions,
  type HydrateOutcome,
  type HydrateStatus,
  hydrate,
} from "./application/env-hydrate";
export { type InitOptions, type InitOutcome, initEnvironment } from "./application/env-init";
export { ENV_AUTHOR_TOOLS } from "./application/env-prompts";
export { type PrunePolicy, pickStale, pruneCache } from "./application/env-prune";
export { computeKey, type LoadedRecipe, loadRecipe } from "./application/env-run";
export { type ServiceOutcome, servicesDown, servicesUp } from "./application/env-services";
export { hello } from "./application/hello";
export { detectRecipe } from "./domain/env-detect";
export { isCacheKey } from "./domain/env-key";
export {
  type EnvRecipe,
  parseRecipe,
  RECIPE_PATH,
  relPathProblem,
  renderRecipe,
} from "./domain/env-recipe";
export type {
  CacheEntry,
  EnvCache,
  EnvExecutor,
  EnvPorts,
  EnvSource,
  RecipeOrigin,
  Scratch,
} from "./ports";
