const cache = new Map<string, RegExp>();

function toRegExp(glob: string): RegExp {
  let out = "";
  let i = 0;
  while (i < glob.length) {
    const c = glob[i] ?? "";
    if (c === "*" && glob[i + 1] === "*") {
      const slash = glob[i + 2] === "/";
      out += slash ? "(?:.*/)?" : ".*";
      i += slash ? 3 : 2;
    } else if (c === "*") {
      out += "[^/]*";
      i += 1;
    } else if (c === "?") {
      out += "[^/]";
      i += 1;
    } else {
      out += /[.+^${}()|[\]\\]/.test(c) ? `\\${c}` : c;
      i += 1;
    }
  }
  return new RegExp(`^${out}$`);
}

/**
 * Matches a repository-relative path against a glob: `**` crosses directories, `*` and `?` do not.
 * A glob that ends with `/` matches everything under that directory.
 */
export function globMatch(glob: string, path: string): boolean {
  const g = glob.endsWith("/") ? `${glob}**` : glob;
  let re = cache.get(g);
  if (re === undefined) {
    re = toRegExp(g);
    cache.set(g, re);
  }
  return re.test(path);
}

export function anyGlobMatches(globs: readonly string[], paths: readonly string[]): boolean {
  return globs.some((g) => paths.some((p) => globMatch(g, p)));
}
