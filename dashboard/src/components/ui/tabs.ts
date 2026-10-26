// Tablist keyboard model (WAI-ARIA APG): roving tabindex, arrows, Home and End.
// Manual activation: arrows move focus, Enter or Space selects (a click on the tab). Each
// destination fetches data on mount, so selecting on every arrow press would fire requests.

export function setupTablist(list: HTMLElement): void {
  const tabs = () => Array.from(list.querySelectorAll<HTMLElement>('[role="tab"]'));
  list.addEventListener("keydown", (e) => {
    const all = tabs();
    const i = all.indexOf(document.activeElement as HTMLElement);
    if (i === -1) return;
    let n = -1;
    if (e.key === "ArrowRight") n = (i + 1) % all.length;
    else if (e.key === "ArrowLeft") n = (i - 1 + all.length) % all.length;
    else if (e.key === "Home") n = 0;
    else if (e.key === "End") n = all.length - 1;
    if (n === -1) return;
    e.preventDefault();
    all.forEach((t, j) => (t.tabIndex = j === n ? 0 : -1));
    all[n].focus();
  });
  // Leaving the tablist hands the tab stop back to the selected tab.
  list.addEventListener("focusout", (e) => {
    if (list.contains(e.relatedTarget as Node | null)) return;
    const all = tabs();
    const sel = all.find((t) => t.getAttribute("aria-selected") === "true") ?? all[0];
    all.forEach((t) => (t.tabIndex = t === sel ? 0 : -1));
  });
}
