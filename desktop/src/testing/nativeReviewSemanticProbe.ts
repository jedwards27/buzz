type SemanticNode = {
  id?: string;
  role?: string;
  name?: string;
  value?: string;
  scrollY: number;
  enabled: boolean;
  focused: boolean;
  frame: { x: number; y: number; width: number; height: number };
  viewport: { width: number; height: number };
};

const IMPLICIT_ROLES: Partial<Record<string, string>> = {
  A: "link",
  BUTTON: "button",
  INPUT: "text-field",
  TEXTAREA: "text-area",
};

function accessibleName(element: HTMLElement): string | undefined {
  const labelledBy = element.getAttribute("aria-labelledby");
  const labelledText = labelledBy
    ?.split(/\s+/)
    .map((id) => document.getElementById(id)?.textContent?.trim())
    .filter(Boolean)
    .join(" ");
  return (
    element.getAttribute("aria-label")?.trim() ||
    labelledText ||
    element.getAttribute("title")?.trim() ||
    (element.getAttribute("role") === "tooltip"
      ? element.textContent?.trim()
      : undefined) ||
    undefined
  );
}

type Frame = SemanticNode["frame"];

/**
 * The part of `frame` inside the viewport, or undefined when none of it is
 * visible. The harness rejects a whole snapshot if any node leaves the
 * viewport, so a visually hidden 1px element at -1px, or a list that overflows
 * the window, must be clipped or skipped here rather than poison every update.
 */
export function clipFrameToViewport(
  frame: Frame,
  viewport: { width: number; height: number },
): Frame | undefined {
  const left = Math.max(frame.x, 0);
  const top = Math.max(frame.y, 0);
  const right = Math.min(frame.x + frame.width, viewport.width);
  const bottom = Math.min(frame.y + frame.height, viewport.height);
  if (right <= left || bottom <= top) return undefined;
  return { x: left, y: top, width: right - left, height: bottom - top };
}

function snapshot(): SemanticNode[] {
  const nodes: SemanticNode[] = [];
  for (const candidate of document.querySelectorAll<HTMLElement>(
    "[data-testid], [role], button, textarea, input, a[href]",
  )) {
    const rect = candidate.getBoundingClientRect();
    const style = window.getComputedStyle(candidate);
    if (
      rect.width <= 0 ||
      rect.height <= 0 ||
      style.display === "none" ||
      style.visibility === "hidden"
    ) {
      continue;
    }
    const id = candidate.dataset.testid;
    const role =
      candidate.getAttribute("role") ?? IMPLICIT_ROLES[candidate.tagName];
    const name = accessibleName(candidate);
    const value =
      candidate instanceof HTMLInputElement ||
      candidate instanceof HTMLTextAreaElement
        ? candidate.value
        : candidate.isContentEditable
          ? candidate.innerText.replace(/\r\n?/g, "\n").replace(/\n$/, "")
          : undefined;
    if (!id && !role && !name) continue;
    const viewport = { width: window.innerWidth, height: window.innerHeight };
    const frame = clipFrameToViewport(
      { x: rect.x, y: rect.y, width: rect.width, height: rect.height },
      viewport,
    );
    if (!frame) continue;
    nodes.push({
      ...(id ? { id } : {}),
      ...(role ? { role } : {}),
      ...(name ? { name } : {}),
      ...(value !== undefined ? { value } : {}),
      scrollY: candidate.scrollTop,
      enabled:
        !candidate.hasAttribute("disabled") &&
        candidate.getAttribute("aria-disabled") !== "true",
      focused: candidate === document.activeElement,
      frame,
      viewport,
    });
  }
  return nodes;
}

export function installNativeReviewSemanticProbe(probeUrl: string): void {
  let scheduled = false;
  const publish = () => {
    scheduled = false;
    const payload = JSON.stringify(snapshot());
    if (!navigator.sendBeacon(probeUrl, payload)) {
      console.error("native review semantic probe beacon was rejected");
    }
  };
  const schedule = () => {
    if (scheduled) return;
    scheduled = true;
    window.requestAnimationFrame(publish);
  };
  new MutationObserver(schedule).observe(document.documentElement, {
    attributes: true,
    childList: true,
    subtree: true,
  });
  window.addEventListener("input", schedule, true);
  window.addEventListener("change", schedule, true);
  window.addEventListener("focusin", schedule);
  window.addEventListener("focusout", schedule);
  window.addEventListener("resize", schedule);
  window.addEventListener("scroll", schedule, true);
  schedule();
}
