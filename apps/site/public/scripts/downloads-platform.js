const normalized = navigator.userAgent.toLowerCase();
const currentPlatform = normalized.includes("mac")
  ? "macos"
  : normalized.includes("win")
    ? "windows"
    : normalized.includes("linux")
      ? "linux"
      : null;

if (currentPlatform) {
  const card = document.querySelector(`[data-platform="${currentPlatform}"]`);
  const badge = card?.querySelector(".downloads-card__recommended");
  if (card && badge) {
    card.classList.add("downloads-card--recommended");
    badge.removeAttribute("hidden");
  }
}
