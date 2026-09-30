const CONFIG = Object.freeze({
  discordUrl: "https://discord.com/",
  serverIp: "85.214.123.45:27015",
  currentPlayers: 18,
  maxPlayers: 40,
  map: "The Island"
});

const $ = (selector, root = document) => root.querySelector(selector);
const $$ = (selector, root = document) => [...root.querySelectorAll(selector)];

function applyHeroArtwork() {
  const heroArt = $("#hero-art");
  if (!heroArt || !window.__WARDOGS_IMG) return;

  heroArt.src = "data:image/webp;base64," + window.__WARDOGS_IMG;
}

function applyConfig() {
  $$("[data-discord-link]").forEach((link) => {
    link.href = CONFIG.discordUrl;
  });

  $$("[data-server-ip]").forEach((node) => {
    node.textContent = CONFIG.serverIp;
  });

  $$("[data-player-short]").forEach((node) => {
    node.textContent = CONFIG.currentPlayers + " / " + CONFIG.maxPlayers;
  });

  const detailedPlayerCount = $("[data-player-count]");
  if (detailedPlayerCount) {
    detailedPlayerCount.innerHTML =
      CONFIG.currentPlayers + " <small>/ " + CONFIG.maxPlayers + "</small>";
  }

  $$("[data-map]").forEach((node) => {
    node.textContent = CONFIG.map;
  });

  const capacityBar = $("[data-capacity-bar]");
  if (capacityBar) {
    const percentage = Math.min(
      100,
      Math.max(0, (CONFIG.currentPlayers / CONFIG.maxPlayers) * 100)
    );
    capacityBar.style.width = percentage + "%";
  }
}

let toastTimer;

function showToast(message) {
  const toast = $(".toast");
  const text = $("[data-toast-text]");
  if (!toast || !text) return;

  text.textContent = message;
  toast.classList.add("show");

  window.clearTimeout(toastTimer);
  toastTimer = window.setTimeout(() => {
    toast.classList.remove("show");
  }, 1800);
}

async function copyServerIp() {
  try {
    await navigator.clipboard.writeText(CONFIG.serverIp);
    showToast("Server-IP kopiert");
  } catch {
    const textarea = document.createElement("textarea");
    textarea.value = CONFIG.serverIp;
    textarea.setAttribute("readonly", "");
    textarea.style.position = "fixed";
    textarea.style.opacity = "0";
    document.body.appendChild(textarea);
    textarea.select();

    try {
      document.execCommand("copy");
      showToast("Server-IP kopiert");
    } catch {
      showToast(CONFIG.serverIp);
    } finally {
      textarea.remove();
    }
  }
}

function setupCopyButtons() {
  $$("[data-copy-ip]").forEach((button) => {
    button.addEventListener("click", copyServerIp);
  });
}

function setupMobileNavigation() {
  const toggle = $(".menu-toggle");
  const nav = $(".main-nav");

  if (!toggle || !nav) return;

  const close = () => {
    toggle.setAttribute("aria-expanded", "false");
    toggle.setAttribute("aria-label", "Navigation öffnen");
    nav.classList.remove("open");
    document.body.classList.remove("menu-open");
  };

  toggle.addEventListener("click", () => {
    const willOpen = toggle.getAttribute("aria-expanded") !== "true";
    toggle.setAttribute("aria-expanded", String(willOpen));
    toggle.setAttribute(
      "aria-label",
      willOpen ? "Navigation schließen" : "Navigation öffnen"
    );
    nav.classList.toggle("open", willOpen);
    document.body.classList.toggle("menu-open", willOpen);
  });

  $$(".nav-link", nav).forEach((link) => {
    link.addEventListener("click", close);
  });

  window.addEventListener("resize", () => {
    if (window.innerWidth > 820) close();
  });
}

function setupHeaderState() {
  const header = $(".site-header");
  if (!header) return;

  const update = () => {
    header.classList.toggle("scrolled", window.scrollY > 14);
  };

  update();
  window.addEventListener("scroll", update, { passive: true });
}

function setupSectionNavigation() {
  const links = $$(".nav-link");
  const sections = links
    .map((link) => {
      const id = link.getAttribute("href");
      return id?.startsWith("#") ? document.querySelector(id) : null;
    })
    .filter(Boolean);

  if (!sections.length || !("IntersectionObserver" in window)) return;

  const observer = new IntersectionObserver(
    (entries) => {
      const visible = entries
        .filter((entry) => entry.isIntersecting)
        .sort((a, b) => b.intersectionRatio - a.intersectionRatio)[0];

      if (!visible) return;

      links.forEach((link) => {
        link.classList.toggle(
          "active",
          link.getAttribute("href") === "#" + visible.target.id
        );
      });
    },
    {
      rootMargin: "-28% 0px -62% 0px",
      threshold: [0.01, 0.2, 0.5]
    }
  );

  sections.forEach((section) => observer.observe(section));
}

function setupRevealAnimations() {
  const items = $$("[data-reveal]");

  if (
    !("IntersectionObserver" in window) ||
    window.matchMedia("(prefers-reduced-motion: reduce)").matches
  ) {
    items.forEach((item) => item.classList.add("revealed"));
    return;
  }

  const observer = new IntersectionObserver(
    (entries) => {
      entries.forEach((entry) => {
        if (!entry.isIntersecting) return;
        entry.target.classList.add("revealed");
        observer.unobserve(entry.target);
      });
    },
    {
      rootMargin: "0px 0px -10% 0px",
      threshold: 0.12
    }
  );

  items.forEach((item, index) => {
    item.style.transitionDelay = Math.min(index * 28, 140) + "ms";
    observer.observe(item);
  });
}

function init() {
  applyHeroArtwork();
  applyConfig();
  setupCopyButtons();
  setupMobileNavigation();
  setupHeaderState();
  setupSectionNavigation();
  setupRevealAnimations();
}

document.addEventListener("DOMContentLoaded", init);
