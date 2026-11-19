(function () {
  "use strict";

  const state = {
    authenticated: false,
    username: "",
    csrfToken: "",
    domain: "",
    basePath: "/deploy/",
    currentView: "overview",
  };

  const VIEW_TITLES = {
    overview: "Overview",
    compat: "Compatibility & Updates",
    probe: "Decoy & Probe Redirection",
    proxy: "Proxy, Inbounds & Audit",
    backups: "Backups & Logs",
    settings: "Settings & Sessions",
  };

  function el(id) {
    return document.getElementById(id);
  }

  function clearNode(node) {
    while (node.firstChild) {
      node.removeChild(node.firstChild);
    }
  }

  function showToast(msg, kind) {
    const container = el("toast-container");
    const item = document.createElement("div");
    item.className =
      "toast" +
      (kind === "ok" ? " toast-ok" : kind === "err" ? " toast-err" : "");
    item.textContent = msg;
    container.appendChild(item);
    window.setTimeout(() => item.remove(), 4200);
  }

  function askConfirm(title, message) {
    return new Promise((resolve) => {
      const modal = el("confirm-modal");
      el("confirm-title").textContent = title;
      el("confirm-message").textContent = message;
      modal.classList.remove("hidden");

      const cleanup = (val) => {
        modal.classList.add("hidden");
        el("confirm-accept").removeEventListener("click", onYes);
        el("confirm-cancel").removeEventListener("click", onNo);
        resolve(val);
      };
      const onYes = () => cleanup(true);
      const onNo = () => cleanup(false);

      el("confirm-accept").addEventListener("click", onYes);
      el("confirm-cancel").addEventListener("click", onNo);
    });
  }

  async function api(path, options) {
    const opts = Object.assign(
      { method: "GET", credentials: "same-origin" },
      options || {},
    );
    opts.headers = Object.assign({}, opts.headers || {});
    if (opts.body !== undefined && typeof opts.body !== "string") {
      opts.body = JSON.stringify(opts.body);
      opts.headers["Content-Type"] = "application/json";
    }
    if (opts.method !== "GET" && opts.method !== "HEAD" && state.csrfToken) {
      opts.headers["X-CSRF-Token"] = state.csrfToken;
    }

    const cleanPath = path.replace(/^\/+/, "");
    const resp = await fetch("./" + cleanPath, opts);
    let data = {};
    try {
      data = await resp.json();
    } catch (_err) {
      data = {};
    }

    if (resp.status === 401 && cleanPath !== "api/auth/login") {
      setLoggedOut();
      throw new Error(data.error || "Session expired. Please sign in again.");
    }
    if (!resp.ok) {
      throw new Error(
        data.error || data.output || "Request failed (" + resp.status + ")",
      );
    }
    return data;
  }

  function makePill(text, tone) {
    const span = document.createElement("span");
    span.className = "pill pill-" + (tone || "neutral");
    span.textContent = text;
    return span;
  }

  function renderKvList(container, rows) {
    clearNode(container);
    rows.forEach(([k, v]) => {
      const row = document.createElement("div");
      row.className = "kv-row";
      const kEl = document.createElement("span");
      kEl.className = "kv-key";
      kEl.textContent = k;
      const vEl = document.createElement("span");
      vEl.className = "kv-val";
      vEl.textContent = v || "-";
      row.appendChild(kEl);
      row.appendChild(vEl);
      container.appendChild(row);
    });
  }

  function setLoggedOut() {
    state.authenticated = false;
    state.csrfToken = "";
    state.username = "";
    el("app-shell").classList.add("hidden");
    el("login-view").classList.remove("hidden");
  }

  function setLoggedIn(authData) {
    state.authenticated = true;
    state.username = authData.username || "admin";
    state.csrfToken = authData.csrf_token || "";
    el("sidebar-username").textContent = state.username;
    el("topbar-domain").textContent = state.domain || window.location.hostname;
    el("login-view").classList.add("hidden");
    el("app-shell").classList.remove("hidden");
    switchView(state.currentView || "overview");
  }

  function switchView(viewName) {
    state.currentView = viewName;
    document.querySelectorAll(".nav-item").forEach((btn) => {
      btn.classList.toggle("active", btn.dataset.view === viewName);
    });
    document.querySelectorAll(".view-section").forEach((sec) => {
      sec.classList.toggle("hidden", sec.id !== "view-" + viewName);
    });
    el("view-title").textContent = VIEW_TITLES[viewName] || "Dashboard";
    closeMobileSidebar();
    loadActiveView();
  }

  function closeMobileSidebar() {
    el("sidebar").classList.remove("open");
    el("sidebar-overlay").classList.add("hidden");
  }

  async function loadOverview() {
    const data = await api("api/overview");
    const kpiBox = el("overview-kpis");
    clearNode(kpiBox);

    const kpis = [
      [
        "3x-ui Version",
        data.xui_tag || "unknown",
        data.deployed ? "Stack deployed" : "Not deployed",
      ],
      [
        "Memory Usage",
        data.metrics.memory,
        "Load: " + (data.metrics.load_avg || "-"),
      ],
      [
        "Disk Usage (/)",
        data.metrics.disk_root,
        "Uptime: " + (data.metrics.uptime || "-"),
      ],
      [
        "Network TCP",
        data.metrics.tcp_cc + " / " + data.metrics.qdisc,
        "BBR & qdisc",
      ],
      [
        "Probe Redirect",
        data.probe.redirect_enabled ? data.probe.active_state : "Disabled",
        data.probe.redirect_enabled ? data.probe.target : "Serving decoy site",
      ],
    ];

    kpis.forEach(([label, val, sub]) => {
      const card = document.createElement("div");
      card.className = "kpi-card";
      const l = document.createElement("div");
      l.className = "kpi-label";
      l.textContent = label;
      const v = document.createElement("div");
      v.className = "kpi-value";
      v.textContent = val;
      const s = document.createElement("div");
      s.className = "kpi-sub";
      s.textContent = sub;
      card.appendChild(l);
      card.appendChild(v);
      card.appendChild(s);
      kpiBox.appendChild(card);
    });

    const contBox = el("overview-containers");
    clearNode(contBox);
    if (!data.containers || data.containers.length === 0) {
      const p = document.createElement("p");
      p.className = "muted";
      p.textContent = "No 3xui_* containers detected.";
      contBox.appendChild(p);
    } else {
      data.containers.forEach((c) => {
        const row = document.createElement("div");
        row.className = "list-item";
        const left = document.createElement("div");
        const title = document.createElement("strong");
        title.textContent = c.name;
        const img = document.createElement("div");
        img.className = "muted";
        img.textContent = c.image + " · " + c.status;
        left.appendChild(title);
        left.appendChild(img);
        row.appendChild(left);
        row.appendChild(
          makePill(c.state, c.state === "running" ? "ok" : "err"),
        );
        contBox.appendChild(row);
      });
    }

    renderKvList(el("overview-endpoints"), [
      ["Management URL", data.proxy.webpanel_url || "-"],
      ["Decoy Website", data.proxy.decoy_url || "-"],
      ["Subscription URL", data.proxy.sub_url || "disabled"],
      [
        "WebPanel Bind",
        "127.0.0.1:" + data.webpanel.port + " (" + data.webpanel.path + ")",
      ],
    ]);

    const certBox = el("overview-certs");
    clearNode(certBox);
    if (!data.certs || data.certs.length === 0) {
      const p = document.createElement("p");
      p.className = "muted";
      p.textContent = "No custom certificates in cert/ (Caddy ACME managed).";
      certBox.appendChild(p);
    } else {
      data.certs.forEach((cert) => {
        const row = document.createElement("div");
        row.className = "list-item";
        const left = document.createElement("span");
        left.textContent = cert.domain + " (exp: " + cert.expires + ")";
        row.appendChild(left);
        row.appendChild(
          makePill(cert.status, cert.status === "ok" ? "ok" : "warn"),
        );
        certBox.appendChild(row);
      });
    }
  }

  async function loadCompat() {
    const data = await api("api/compat");
    const p = data.parsed || {};
    renderKvList(el("compat-summary"), [
      ["Detected Version", p.detected_version || "unknown"],
      ["Classification", p.classification || "unknown"],
      ["Panel Binary", p.binary || "unknown"],
      [
        "DB Path / Schema",
        (p.db_path || "-") + " (" + (p.schema || "unknown") + ")",
      ],
      ["Bin Folder", p.bin_dir || "-"],
    ]);
    el("compat-output").textContent = data.output || "";
  }

  async function loadProbeAndDecoy() {
    const [bundle, decoy] = await Promise.all([
      api("api/probe"),
      api("api/decoy"),
    ]);
    const cfg = bundle.config || {};
    const st = bundle.state || {};

    el("probe-enabled").checked = !!cfg.PROBE_REDIRECT_ENABLED;
    el("probe-target").value =
      cfg.PROBE_REDIRECT_TARGET || "https://www.cloudflare.com";
    el("probe-status").value = cfg.PROBE_REDIRECT_STATUS || "302";
    el("probe-interval").value = cfg.PROBE_CHECK_INTERVAL || 60;
    el("probe-fallback-mode").value = cfg.PROBE_FALLBACK_MODE || "decoy";
    el("probe-fallback-url").value = cfg.PROBE_FALLBACK_URL || "";

    el("rule-scanners").checked = !!cfg.PROBE_DETECT_SCANNERS;
    el("rule-cli").checked = !!cfg.PROBE_DETECT_CLI;
    el("rule-empty-ua").checked = !!cfg.PROBE_DETECT_EMPTY_UA;
    el("rule-methods").checked = !!cfg.PROBE_DETECT_BAD_METHODS;
    el("rule-paths").checked = !!cfg.PROBE_DETECT_PATHS;
    el("rule-crawlers").checked = !!cfg.PROBE_DETECT_CRAWLERS;

    el("probe-custom-ua").value = cfg.PROBE_CUSTOM_UA || "";
    el("probe-custom-paths").value = cfg.PROBE_CUSTOM_PATHS || "";
    el("probe-block-cidrs").value = cfg.PROBE_BLOCK_CIDRS || "";
    el("probe-allow-cidrs").value = cfg.PROBE_ALLOW_CIDRS || "";

    const badge = el("probe-state-badge");
    const active = st.active_state || "primary";
    badge.textContent = active;
    badge.className =
      "pill " +
      (active === "primary"
        ? "pill-ok"
        : active === "disabled"
          ? "pill-neutral"
          : "pill-warn");

    const banner = el("probe-health-banner");
    if (cfg.PROBE_REDIRECT_ENABLED && st.reason) {
      banner.textContent =
        "Active state: " +
        active +
        " · " +
        st.reason +
        (st.last_checked ? " (checked " + st.last_checked + ")" : "");
      banner.className = "alert " + (st.primary_ok ? "alert-ok" : "alert-info");
      banner.classList.remove("hidden");
    } else {
      banner.classList.add("hidden");
    }

    const protBox = el("probe-protected-paths");
    clearNode(protBox);
    (bundle.protected_paths || []).forEach((path) => {
      protBox.appendChild(makePill(path, "ok"));
    });

    el("decoy-theme").value = decoy.theme || "cloud";
    el("decoy-name").value = decoy.site_name || "";
    el("decoy-tagline").value = decoy.tagline || "";
    el("decoy-email").value = decoy.contact_email || "";
    const customPill = el("decoy-custom-pill");
    customPill.textContent = decoy.custom_html_active
      ? "Custom HTML"
      : "Multi-Page Static";
    customPill.className =
      "pill " + (decoy.custom_html_active ? "pill-warn" : "pill-ok");
  }

  async function loadProxyInbounds() {
    const res = await api("api/inbounds");
    el("inbounds-output").textContent = res.output || "No inbound output.";
  }

  async function runAudit() {
    const res = await api("api/audit", { method: "POST", body: {} });
    const countsBox = el("audit-counts");
    clearNode(countsBox);
    countsBox.appendChild(makePill("PASS: " + res.counts.pass, "ok"));
    countsBox.appendChild(makePill("WARN: " + res.counts.warn, "warn"));
    countsBox.appendChild(
      makePill(
        "FAIL: " + res.counts.fail,
        res.counts.fail > 0 ? "err" : "neutral",
      ),
    );

    const listBox = el("audit-items");
    clearNode(listBox);
    (res.items || []).forEach((it) => {
      const row = document.createElement("div");
      row.className = "list-item";
      const txt = document.createElement("span");
      txt.textContent = it.message;
      const tone =
        it.level === "PASS" ? "ok" : it.level === "WARN" ? "warn" : "err";
      row.appendChild(txt);
      row.appendChild(makePill(it.level, tone));
      listBox.appendChild(row);
    });
  }

  async function loadBackupsAndLogs() {
    const [bData, lData] = await Promise.all([
      api("api/backups"),
      api(
        "api/logs?source=" +
          encodeURIComponent(el("log-source").value) +
          "&level=" +
          encodeURIComponent(el("log-level").value) +
          "&lines=180",
      ),
    ]);

    const box = el("backups-list");
    clearNode(box);
    if (!bData.backups || bData.backups.length === 0) {
      const p = document.createElement("p");
      p.className = "muted";
      p.textContent = "No backup archives found.";
      box.appendChild(p);
    } else {
      bData.backups.forEach((b) => {
        const row = document.createElement("div");
        row.className = "list-item";
        const left = document.createElement("div");
        const title = document.createElement("strong");
        title.textContent = b.name;
        const meta = document.createElement("div");
        meta.className = "muted";
        meta.textContent =
          Math.round(b.size_bytes / 1024) + " KiB · " + b.modified_at;
        left.appendChild(title);
        left.appendChild(meta);
        row.appendChild(left);
        box.appendChild(row);
      });
    }

    el("logs-output").textContent =
      lData.lines && lData.lines.length
        ? lData.lines.join("\n")
        : lData.note || lData.error || "(empty)";
  }

  async function loadSettingsAndSessions() {
    const [ov, sessData] = await Promise.all([
      api("api/overview"),
      api("api/auth/sessions"),
    ]);
    renderKvList(el("settings-summary"), [
      ["Exclusive Path", ov.webpanel.path],
      ["Allowed Domain", ov.proxy.domain],
      ["Loopback Bind", "127.0.0.1:" + ov.webpanel.port],
      ["Idle Timeout", ov.webpanel.idle_minutes + " minutes"],
    ]);

    const box = el("sessions-list");
    clearNode(box);
    (sessData.sessions || []).forEach((s) => {
      const row = document.createElement("div");
      row.className = "list-item";
      const left = document.createElement("div");
      const title = document.createElement("strong");
      title.textContent = s.username + " (" + s.ip + ")";
      const sub = document.createElement("div");
      sub.className = "muted";
      sub.textContent =
        "Last seen: " + s.last_seen + " · " + (s.user_agent || "unknown agent");
      left.appendChild(title);
      left.appendChild(sub);
      row.appendChild(left);
      row.appendChild(
        makePill(
          s.current ? "Current" : "Active",
          s.current ? "ok" : "neutral",
        ),
      );
      box.appendChild(row);
    });
  }

  async function loadActiveView() {
    try {
      switch (state.currentView) {
        case "overview":
          await loadOverview();
          break;
        case "compat":
          await loadCompat();
          break;
        case "probe":
          await loadProbeAndDecoy();
          break;
        case "proxy":
          await loadProxyInbounds();
          break;
        case "backups":
          await loadBackupsAndLogs();
          break;
        case "settings":
          await loadSettingsAndSessions();
          break;
      }
    } catch (err) {
      showToast(err.message, "err");
    }
  }

  function wireEvents() {
    // Login
    el("login-form").addEventListener("submit", async (e) => {
      e.preventDefault();
      el("login-error").classList.add("hidden");
      try {
        const res = await api("api/auth/login", {
          method: "POST",
          body: {
            username: el("login-username").value.trim(),
            password: el("login-password").value,
          },
        });
        el("login-password").value = "";
        setLoggedIn(res);
      } catch (err) {
        el("login-error").textContent = err.message;
        el("login-error").classList.remove("hidden");
      }
    });

    el("logout-btn").addEventListener("click", async () => {
      try {
        await api("api/auth/logout", { method: "POST", body: {} });
      } catch (_err) {
        // Ignore error on logout
      }
      setLoggedOut();
    });

    // Navigation
    document.querySelectorAll(".nav-item").forEach((btn) => {
      btn.addEventListener("click", () => switchView(btn.dataset.view));
    });
    el("sidebar-open").addEventListener("click", () => {
      el("sidebar").classList.add("open");
      el("sidebar-overlay").classList.remove("hidden");
    });
    el("sidebar-close").addEventListener("click", closeMobileSidebar);
    el("sidebar-overlay").addEventListener("click", closeMobileSidebar);
    el("refresh-view-btn").addEventListener("click", loadActiveView);

    el("theme-toggle").addEventListener("click", () => {
      const root = document.documentElement;
      const next = root.dataset.theme === "dark" ? "light" : "dark";
      root.dataset.theme = next;
      el("theme-toggle").textContent = next === "dark" ? "Light" : "Dark";
    });

    // Lifecycle buttons
    document.querySelectorAll("[data-lifecycle]").forEach((btn) => {
      btn.addEventListener("click", async () => {
        const action = btn.dataset.lifecycle;
        if (action === "stop" || action === "restart") {
          const ok = await askConfirm(
            "Confirm Stack Action",
            "Run '" + action + "' on the 3x-ui deployment stack?",
          );
          if (!ok) return;
        }
        try {
          const res = await api("api/lifecycle", {
            method: "POST",
            body: { action },
          });
          if (el("overview-op-output")) {
            el("overview-op-output").textContent = res.output || "Completed.";
          }
          showToast("Action '" + action + "' completed.", "ok");
          loadActiveView();
        } catch (err) {
          showToast(err.message, "err");
        }
      });
    });

    // Compatibility & Updates
    el("compat-refresh-btn").addEventListener("click", loadCompat);
    el("compat-test-form").addEventListener("submit", async (e) => {
      e.preventDefault();
      const tag = el("compat-test-tag").value.trim();
      try {
        const res = await api("api/compat/test", {
          method: "POST",
          body: { tag },
        });
        el("update-output").textContent = res.output || "Pre-flight passed.";
        showToast("Pre-flight check passed for " + tag, "ok");
      } catch (err) {
        el("update-output").textContent = err.message;
        showToast(err.message, "err");
      }
    });

    el("update-form").addEventListener("submit", async (e) => {
      e.preventDefault();
      const tag = el("update-tag-input").value.trim();
      const force = el("update-force-compat").checked;
      const ok = await askConfirm(
        "Confirm 3x-ui Update",
        "Pull and apply " +
          (tag || "latest release") +
          "? Automatic rollback is enabled if health verification fails.",
      );
      if (!ok) return;
      try {
        const res = await api("api/update", {
          method: "POST",
          body: { tag: tag || null, force_compat: force },
        });
        el("update-output").textContent = res.output || "Update complete.";
        showToast("Update completed successfully.", "ok");
        loadCompat();
      } catch (err) {
        el("update-output").textContent = err.message;
        showToast(err.message, "err");
      }
    });

    el("rollback-btn").addEventListener("click", async () => {
      const ok = await askConfirm(
        "Confirm Rollback",
        "Restore compose.yaml.bak and recreate previous containers?",
      );
      if (!ok) return;
      try {
        const res = await api("api/rollback", { method: "POST", body: {} });
        el("update-output").textContent = res.output || "Rollback complete.";
        showToast("Rollback completed.", "ok");
        loadCompat();
      } catch (err) {
        el("update-output").textContent = err.message;
        showToast(err.message, "err");
      }
    });

    // Probe Presets & Form
    document.querySelectorAll("[data-preset]").forEach((btn) => {
      btn.addEventListener("click", () => {
        el("probe-target").value = btn.dataset.preset;
      });
    });

    el("probe-check-btn").addEventListener("click", async () => {
      const url = el("probe-target").value.trim();
      try {
        const res = await api("api/probe/check", {
          method: "POST",
          body: { url },
        });
        const p = res.probe || {};
        showToast(
          p.reachable
            ? "Reachable: HTTP " + p.status_code + " (" + p.latency_ms + "ms)"
            : "Unreachable: " + (p.error || "failed"),
          p.reachable ? "ok" : "err",
        );
      } catch (err) {
        showToast(err.message, "err");
      }
    });

    el("probe-run-health-btn").addEventListener("click", async () => {
      try {
        const res = await api("api/probe/check", { method: "POST", body: {} });
        showToast(
          "Active state: " + (res.state ? res.state.active_state : "checked"),
          "ok",
        );
        loadProbeAndDecoy();
      } catch (err) {
        showToast(err.message, "err");
      }
    });

    el("probe-form").addEventListener("submit", async (e) => {
      e.preventDefault();
      try {
        await api("api/probe", {
          method: "PUT",
          body: {
            PROBE_REDIRECT_ENABLED: el("probe-enabled").checked,
            PROBE_REDIRECT_TARGET: el("probe-target").value.trim(),
            PROBE_REDIRECT_STATUS: el("probe-status").value,
            PROBE_CHECK_INTERVAL: Number(el("probe-interval").value || 60),
            PROBE_FALLBACK_MODE: el("probe-fallback-mode").value,
            PROBE_FALLBACK_URL: el("probe-fallback-url").value.trim(),
            PROBE_DETECT_SCANNERS: el("rule-scanners").checked,
            PROBE_DETECT_CLI: el("rule-cli").checked,
            PROBE_DETECT_EMPTY_UA: el("rule-empty-ua").checked,
            PROBE_DETECT_BAD_METHODS: el("rule-methods").checked,
            PROBE_DETECT_PATHS: el("rule-paths").checked,
            PROBE_DETECT_CRAWLERS: el("rule-crawlers").checked,
            PROBE_CUSTOM_UA: el("probe-custom-ua").value.trim(),
            PROBE_CUSTOM_PATHS: el("probe-custom-paths").value.trim(),
            PROBE_BLOCK_CIDRS: el("probe-block-cidrs").value.trim(),
            PROBE_ALLOW_CIDRS: el("probe-allow-cidrs").value.trim(),
          },
        });
        showToast("Probe redirection rules saved and synced to Caddy.", "ok");
        loadProbeAndDecoy();
      } catch (err) {
        showToast(err.message, "err");
      }
    });

    // Simulator
    el("sim-preset-browser").addEventListener("click", () => {
      el("sim-method").value = "GET";
      el("sim-path").value = "/services.html";
      el("sim-ua").value =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) Safari/605.1.15";
    });
    el("sim-preset-scanner").addEventListener("click", () => {
      el("sim-method").value = "GET";
      el("sim-path").value = "/";
      el("sim-ua").value =
        "Mozilla/5.0 (compatible; Nuclei - Open-source project)";
    });
    el("sim-preset-env").addEventListener("click", () => {
      el("sim-method").value = "GET";
      el("sim-path").value = "/.env";
      el("sim-ua").value = "Mozilla/5.0";
    });

    el("sim-form").addEventListener("submit", async (e) => {
      e.preventDefault();
      try {
        const res = await api("api/probe/simulate", {
          method: "POST",
          body: {
            method: el("sim-method").value,
            path: el("sim-path").value,
            user_agent: el("sim-ua").value,
            client_ip: el("sim-ip").value,
          },
        });
        const box = el("sim-result");
        box.textContent =
          "Decision: " +
          res.decision.toUpperCase() +
          " (" +
          res.status +
          " -> " +
          res.target +
          ") · Rule: " +
          res.matched_rule +
          " · " +
          res.reason;
        box.className =
          "alert " + (res.decision === "redirect" ? "alert-info" : "alert-ok");
        box.classList.remove("hidden");
      } catch (err) {
        showToast(err.message, "err");
      }
    });

    // Decoy form
    el("decoy-form").addEventListener("submit", async (e) => {
      e.preventDefault();
      try {
        await api("api/decoy", {
          method: "PUT",
          body: {
            theme: el("decoy-theme").value,
            site_name: el("decoy-name").value.trim(),
            tagline: el("decoy-tagline").value.trim(),
            contact_email: el("decoy-email").value.trim(),
            custom_html: el("decoy-custom-html").value,
          },
        });
        showToast("Decoy website updated.", "ok");
        loadProbeAndDecoy();
      } catch (err) {
        showToast(err.message, "err");
      }
    });

    // Audit, Backups, Geo, Logs
    el("run-audit-btn").addEventListener("click", () => {
      runAudit().catch((err) => showToast(err.message, "err"));
    });

    el("create-backup-btn").addEventListener("click", async () => {
      try {
        await api("api/backups", { method: "POST", body: {} });
        showToast("Backup archive created.", "ok");
        loadBackupsAndLogs();
      } catch (err) {
        showToast(err.message, "err");
      }
    });

    el("prune-form").addEventListener("submit", async (e) => {
      e.preventDefault();
      const keep = Number(el("prune-keep").value || 7);
      const ok = await askConfirm(
        "Prune Backups",
        "Keep only the newest " + keep + " backup archives?",
      );
      if (!ok) return;
      try {
        const res = await api("api/backups/prune", {
          method: "POST",
          body: { keep },
        });
        showToast(
          "Pruned " +
            (res.removed ? res.removed.length : 0) +
            " old archive(s).",
          "ok",
        );
        loadBackupsAndLogs();
      } catch (err) {
        showToast(err.message, "err");
      }
    });

    document.querySelectorAll("[data-geo]").forEach((btn) => {
      btn.addEventListener("click", async () => {
        const scope = btn.dataset.geo;
        const ok = await askConfirm(
          "Update GeoIP/GeoSite",
          "Download '" + scope + "' geo datasets and restart Xray?",
        );
        if (!ok) return;
        try {
          await api("api/geo-update", { method: "POST", body: { scope } });
          showToast("Updated GeoIP/GeoSite (" + scope + ").", "ok");
        } catch (err) {
          showToast(err.message, "err");
        }
      });
    });

    el("logs-refresh-btn").addEventListener("click", () => {
      loadBackupsAndLogs().catch((err) => showToast(err.message, "err"));
    });
    el("log-source").addEventListener("change", () => {
      loadBackupsAndLogs().catch((err) => showToast(err.message, "err"));
    });

    // Password & Sessions
    el("password-form").addEventListener("submit", async (e) => {
      e.preventDefault();
      const cur = el("pw-current").value;
      const npw = el("pw-new").value;
      const cpw = el("pw-confirm").value;
      if (npw !== cpw) {
        showToast("New passwords do not match.", "err");
        return;
      }
      try {
        const res = await api("api/auth/change-password", {
          method: "POST",
          body: { current_password: cur, new_password: npw },
        });
        state.csrfToken = res.csrf_token || state.csrfToken;
        el("pw-current").value = "";
        el("pw-new").value = "";
        el("pw-confirm").value = "";
        showToast(res.message || "Password updated.", "ok");
        loadSettingsAndSessions();
      } catch (err) {
        showToast(err.message, "err");
      }
    });

    el("revoke-others-btn").addEventListener("click", async () => {
      const ok = await askConfirm(
        "Revoke Other Sessions",
        "Sign out all other active browser sessions?",
      );
      if (!ok) return;
      try {
        const res = await api("api/auth/sessions/revoke-others", {
          method: "POST",
          body: {},
        });
        showToast("Revoked " + (res.revoked || 0) + " session(s).", "ok");
        loadSettingsAndSessions();
      } catch (err) {
        showToast(err.message, "err");
      }
    });
  }

  async function bootstrap() {
    wireEvents();
    try {
      const status = await api("api/auth/status");
      state.domain = status.domain || window.location.hostname;
      state.basePath = status.base_path || "/deploy/";
      if (state.domain) {
        const pill = el("login-domain-pill");
        pill.textContent =
          "Domain: " + state.domain + " (" + state.basePath + ")";
        pill.classList.remove("hidden");
      }
      if (status.authenticated) {
        setLoggedIn(status);
      } else {
        setLoggedOut();
      }
    } catch (err) {
      setLoggedOut();
      el("login-error").textContent = err.message;
      el("login-error").classList.remove("hidden");
    }
  }

  document.addEventListener("DOMContentLoaded", bootstrap);
})();
