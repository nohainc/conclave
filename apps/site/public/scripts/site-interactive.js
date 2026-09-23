// Interactive tabs and clipboard copy handlers for Conclave AX landing page
(() => {
  // Live region for screen reader announcements
  let announcer = document.getElementById("site-live-announcer");
  if (!announcer) {
    announcer = document.createElement("div");
    announcer.id = "site-live-announcer";
    announcer.setAttribute("aria-live", "polite");
    announcer.setAttribute("aria-atomic", "true");
    announcer.className = "sr-only";
    document.body.appendChild(announcer);
  }

  /** @param {string} message */
  function announce(message) {
    if (announcer) {
      announcer.textContent = "";
      setTimeout(() => {
        if (announcer) {
          announcer.textContent = message;
        }
      }, 50);
    }
  }

  // 1. WAI-ARIA Tabbed workflow switcher
  const tabContainers = document.querySelectorAll("[data-interactive-tabs]");
  tabContainers.forEach((container) => {
    /** @type {HTMLElement[]} */
    const tabButtons = Array.from(
      container.querySelectorAll("[data-tab-target]"),
    );
    /** @type {HTMLElement[]} */
    const tabPanels = Array.from(
      container.querySelectorAll("[data-tab-panel]"),
    );

    /**
     * @param {HTMLElement} button
     * @param {boolean} [shouldFocus=false]
     */
    function activateTab(button, shouldFocus = false) {
      const targetId = button.getAttribute("data-tab-target");

      tabButtons.forEach((btn) => {
        const isSelected = btn === button;
        btn.setAttribute("aria-selected", isSelected ? "true" : "false");
        btn.setAttribute("tabindex", isSelected ? "0" : "-1");
        btn.classList.toggle("is-active", isSelected);
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

      if (shouldFocus) {
        button.focus();
      }
    }

    tabButtons.forEach((button, index) => {
      button.addEventListener("click", () => {
        activateTab(button, false);
      });

      button.addEventListener("keydown", (event) => {
        const e = /** @type {KeyboardEvent} */ (event);
        let newIndex = index;
        if (e.key === "ArrowRight" || e.key === "ArrowDown") {
          e.preventDefault();
          newIndex = (index + 1) % tabButtons.length;
          activateTab(tabButtons[newIndex], true);
        } else if (e.key === "ArrowLeft" || e.key === "ArrowUp") {
          e.preventDefault();
          newIndex = (index - 1 + tabButtons.length) % tabButtons.length;
          activateTab(tabButtons[newIndex], true);
        } else if (e.key === "Home") {
          e.preventDefault();
          activateTab(tabButtons[0], true);
        } else if (e.key === "End") {
          e.preventDefault();
          activateTab(tabButtons[tabButtons.length - 1], true);
        }
      });
    });
  });

  // 2. Copy code buttons with live feedback
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
        announce("Code snippet copied to clipboard");
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
