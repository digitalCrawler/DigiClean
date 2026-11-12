// DigiClean website: download links, platform detection, version number and
// the mobile menu. Runs on every page; each part skips what a page lacks.
(function () {
  var repo = window.DIGICLEAN_REPO;
  var published = !!repo && repo.indexOf("__") !== 0;
  var base = published ? "https://github.com/" + repo : null;
  if (!published) document.documentElement.classList.add("is-preview");

  // Every download points at the newest release; file names are stable.
  document.querySelectorAll("[data-asset]").forEach(function (a) {
    a.href = published ? base + "/releases/latest/download/" + a.getAttribute("data-asset") : "index.html#download";
  });
  // Repository links: data-gh is the path after the repository URL.
  document.querySelectorAll("[data-gh]").forEach(function (a) {
    a.href = published ? base + a.getAttribute("data-gh") : "index.html#download";
  });
  document.querySelectorAll("[data-year]").forEach(function (el) {
    el.textContent = new Date().getFullYear();
  });

  // Recommend the visitor's platform.
  var platform = ((navigator.userAgentData && navigator.userAgentData.platform) || navigator.platform || navigator.userAgent || "").toLowerCase();
  var mobile = /android|iphone|ipad|ipod/.test((navigator.userAgent || "").toLowerCase());
  var os = mobile ? null : /win/.test(platform) ? "windows" : /mac/.test(platform) ? "mac" : /linux|x11|cros/.test(platform) ? "linux" : null;
  var labels = {
    windows: ["Download for Windows", "Installer · 64-bit"],
    mac: ["Download for macOS", "Apple silicon & Intel"],
    linux: ["Download for Linux", "AppImage · x86_64"]
  };
  var row = os && document.querySelector('.dl-row[data-os="' + os + '"]');
  if (row) {
    row.classList.add("is-yours");
    var href = row.querySelector(".btn").href;
    document.querySelectorAll("[data-primary-download]").forEach(function (a) {
      a.href = href;
      var label = a.querySelector("[data-label]");
      var sub = a.querySelector("[data-sub]");
      if (label) label.textContent = labels[os][0];
      if (sub) sub.textContent = labels[os][1];
    });
  }

  // Latest version (best effort; every link works without it).
  if (published && window.fetch && document.querySelector("[data-version]")) {
    fetch("https://api.github.com/repos/" + repo + "/releases/latest")
      .then(function (r) { return r.ok ? r.json() : null; })
      .then(function (rel) {
        if (!rel || !rel.tag_name) return;
        var version = rel.tag_name.replace(/^v/, "");
        var date = rel.published_at ? new Date(rel.published_at).toLocaleDateString(undefined, { year: "numeric", month: "long", day: "numeric" }) : "";
        document.querySelectorAll("[data-version]").forEach(function (el) {
          el.textContent = "Version " + version + (date ? " · " + date : "");
        });
      })
      .catch(function () {});
  }

  // Mobile menu.
  var toggle = document.querySelector(".menu-btn");
  var menu = document.getElementById("mobile-menu");
  if (toggle && menu) {
    var set = function (open) {
      toggle.setAttribute("aria-expanded", String(open));
      toggle.setAttribute("aria-label", open ? "Close menu" : "Open menu");
      menu.hidden = !open;
      toggle.querySelector(".i-open").style.display = open ? "none" : "";
      toggle.querySelector(".i-close").style.display = open ? "" : "none";
    };
    toggle.addEventListener("click", function () { set(menu.hidden); });
    menu.addEventListener("click", function (e) { if (e.target.closest("a")) set(false); });
    document.addEventListener("keydown", function (e) {
      if (e.key === "Escape" && !menu.hidden) { set(false); toggle.focus(); }
    });
  }
})();
