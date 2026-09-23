// Interactive tabs and clipboard copy handlers for Conclave AX landing page
(() => {
  // 1. Tabbed workflow switcher
  const tabContainers = document.querySelectorAll("[data-interactive-tabs]");
  tabContainers.forEach((container) => {
    const tabButtons = container.querySelectorAll("[data-tab-target]");
    const tabPanels = container.querySelectorAll("[data-tab-panel]");

    tabButtons.forEach((button) => {
      button.addEventListener("click", () => {
        const targetId = button.getAttribute("data-tab-target");

        tabButtons.forEach((btn) => {
          btn.setAttribute("aria-selected", btn === button ? "true" : "false");
          btn.classList.toggle("is-active", btn === button);
        });

        tabPanels.forEach((panel) => {
          const isMatch = panel.getAttribute("data-tab-panel") === targetId;
          if (isMatch) {
            panel.removeAttribute("hidden");
          } else {
            panel.setAttribute("hidden", "");
          }
          panel.classList.toggle("is-active", isMatch);
        });
      });
    });
  });

  // 2. Copy code buttons
  const copyButtons = document.querySelectorAll("[data-copy-text]");
  copyButtons.forEach((button) => {
    button.addEventListener("click", async () => {
      const textToCopy = button.getAttribute("data-copy-text");
      if (!textToCopy) return;

      try {
        await navigator.clipboard.writeText(textToCopy);
        const originalLabel = button.textContent;
        button.textContent = "Copied!";
        button.classList.add("is-copied");
        setTimeout(() => {
          button.textContent = originalLabel;
          button.classList.remove("is-copied");
        }, 2000);
      } catch {
        // Fallback for clipboard failures
      }
    });
  });
})();
