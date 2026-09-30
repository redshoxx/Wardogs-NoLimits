const CONFIG = {
  discordUrl: "https://discord.com/",
  serverIp: "85.214.123.45:27015"
};

const design = document.querySelector(".design");
if (design && window.__WARDOGS_IMG) {
  design.src = "data:image/webp;base64," + window.__WARDOGS_IMG;
}

document.querySelectorAll('[data-link="discord"]').forEach(link => {
  link.href = CONFIG.discordUrl;
  link.target = "_blank";
  link.rel = "noopener noreferrer";
});

const toast = document.querySelector(".toast");
let toastTimer;

document.querySelector("[data-copy-ip]").addEventListener("click", async () => {
  try {
    await navigator.clipboard.writeText(CONFIG.serverIp);
  } catch {
    const input = document.createElement("textarea");
    input.value = CONFIG.serverIp;
    document.body.appendChild(input);
    input.select();
    document.execCommand("copy");
    input.remove();
  }
  clearTimeout(toastTimer);
  toast.classList.add("show");
  toastTimer = setTimeout(() => toast.classList.remove("show"), 1600);
});
