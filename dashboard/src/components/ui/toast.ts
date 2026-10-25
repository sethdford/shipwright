// Toast: role=status for results, role=alert for errors. One at a time.

let timer: ReturnType<typeof setTimeout> | null = null;

export function toast(message: string, kind: "status" | "error" = "status"): void {
  let el = document.getElementById("toast");
  if (!el) {
    el = document.createElement("div");
    el.id = "toast";
    el.className = "toast";
    document.body.append(el);
  }
  el.setAttribute("role", kind === "error" ? "alert" : "status");
  el.dataset.kind = kind;
  el.textContent = message;
  el.hidden = false;
  if (timer) clearTimeout(timer);
  timer = setTimeout(() => {
    if (el) el.hidden = true;
  }, 4000);
}
