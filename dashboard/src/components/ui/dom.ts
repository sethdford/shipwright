// Tiny DOM builder. Text always goes through textContent, never markup strings.

type Child = Node | string | null | undefined | false;
type Props = Record<string, string | number | boolean | EventListener | null | undefined>;

export function h<K extends keyof HTMLElementTagNameMap>(
  tag: K,
  props?: Props | null,
  ...children: Child[]
): HTMLElementTagNameMap[K] {
  const el = document.createElement(tag);
  for (const [k, v] of Object.entries(props ?? {})) {
    if (v == null || v === false) continue;
    if (k === "class") el.className = String(v);
    else if (k === "text") el.textContent = String(v);
    else if (k.startsWith("on") && typeof v === "function") {
      el.addEventListener(k.slice(2), v as EventListener);
    } else el.setAttribute(k, v === true ? "" : String(v));
  }
  for (const c of children) if (c) el.append(c);
  return el;
}

/**
 * Elements that start hidden and are later shown by a view with `style.display = ""` are
 * marked `data-hidden` in index.html (the CSP forbids inline style attributes). This turns
 * the marker into an inline display:none through the CSSOM, which the CSP allows.
 */
export function hydrateInitialHidden(root: ParentNode = document): void {
  root.querySelectorAll<HTMLElement>("[data-hidden]").forEach((el) => {
    el.style.display = "none";
    el.removeAttribute("data-hidden");
  });
}
