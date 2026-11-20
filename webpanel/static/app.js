(function () {
  "use strict";

  const THEME_STORAGE_KEY = "3xui_deploy_theme";

  const VIEW_META = {
    overview: ["Dashboard", "System health, containers & live metrics"],
    certs: ["SSL Certificates", "Let's Encrypt issuance, renewal & revocation"],
    network: [
      "Domains & Network",
      "Reverse proxy, listen IP, DNS, BBR & firewall",
    ],
    probe: [
      "Decoy & Stealth",
      "Bot/probe redirection, simulator & decoy website",
    ],
    inbounds: [
      "Inbounds & Audit",
      "Xray listeners, Caddy routing & security audit",
    ],
    deploy: [
      "Deploy & Updates",
      "Stack setup, 3x-ui compatibility & rollbacks",
    ],
    operations: [
      "Backups, Logs & History",
      "Archives, cron schedules, logs & task history",
    ],
    settings: [
      "Settings & Access",
      "Credentials, session timeout & active sessions",
    ],
  };

  const state = {
    authenticated: false,
    username: "",
    csrfToken: "",
    domain: "",
    basePath: "/deploy/",
    version: "",
    currentView: "overview",
    activeTabs: {
      network: "proxy",
      probe: "rules",
      operations: "backups",
    },
    activeJobId: "",
    jobStream: null,
    jobPollTimer: null,
    jobCursor: 0,
    jobLines: [],
  };

  function el(id) {
    return document.getElementById(id);
  }

  function clearNode(node) {
    if (!node) return;
    while (node.firstChild) {
      node.removeChild(node.firstChild);
    }
  }

  function showToast(msg, kind) {
    const container = el("toast-container");
    if (!container) return;
    const item = document.createElement("div");
    item.className =
      "toast" +
      (kind === "ok" ? " toast-ok" : kind === "err" ? " toast-err" : "");
    item.textContent = msg;
    container.appendChild(item);
    window.setTimeout(() => item.remove(), 4600);
  }

  function makePill(text, tone) {
    const span = document.createElement("span");
    span.className = "pill pill-" + (tone || "neutral");
    span.textContent = text;
    return span;
  }

  function makeMeter(pct, tone) {
    const bar = document.createElement("progress");
    bar.className = "meter meter-" + (tone || "accent");
    bar.max = 100;
    bar.value = Math.max(0, Math.min(100, Number(pct) || 0));
    return bar;
  }

  function copyText(value, label) {
    if (!value) return;
    if (navigator.clipboard && navigator.clipboard.writeText) {
      navigator.clipboard
        .writeText(value)
        .then(() => showToast((label || "Text") + " copied.", "ok"))
        .catch(() => showToast("Copy unavailable in browser context.", "err"));
    } else {
      showToast("Clipboard API unavailable.", "err");
    }
  }

  function setBusy(button, busy, busyText) {
    if (!button) return;
    if (busy) {
      button.dataset.prevText = button.textContent || "";
      if (busyText) button.textContent = busyText;
      button.disabled = true;
    } else {
      button.disabled = false;
      if (button.dataset.prevText) {
        button.textContent = button.dataset.prevText;
        delete button.dataset.prevText;
      }
    }
  }

  function askConfirm(optsOrTitle, legacyMsg) {
    const opts =
      typeof optsOrTitle === "string"
        ? { title: optsOrTitle, message: legacyMsg || "" }
        : optsOrTitle || {};

    return new Promise((resolve) => {
      const modal = el("confirm-modal");
      const badge = el("confirm-tone-badge");
      const bulletsEl = el("confirm-bullets");
      const phraseWrap = el("confirm-phrase-wrap");
      const phraseInput = el("confirm-phrase-input");
      const acceptBtn = el("confirm-accept");
      const cancelBtn = el("confirm-cancel");

      const tone = opts.tone || "warn";
      badge.textContent =
        tone === "danger"
          ? "High Risk"
          : tone === "info"
            ? "Notice"
            : "Confirm";
      badge.className =
        "pill " +
        (tone === "danger"
          ? "pill-err"
          : tone === "info"
            ? "pill-info"
            : "pill-warn");

      el("confirm-title").textContent = opts.title || "Confirm Action";
      el("confirm-message").textContent = opts.message || "";

      clearNode(bulletsEl);
      if (Array.isArray(opts.bullets) && opts.bullets.length > 0) {
        opts.bullets.forEach((b) => {
          const li = document.createElement("li");
          li.textContent = b;
          bulletsEl.appendChild(li);
        });
        bulletsEl.classList.remove("hidden");
      } else {
        bulletsEl.classList.add("hidden");
      }

      const reqPhrase = (opts.requirePhrase || "").trim();
      phraseInput.value = "";
      if (reqPhrase) {
        el("confirm-phrase-label").textContent =
          "Type '" + reqPhrase + "' to confirm";
        phraseInput.placeholder = reqPhrase;
        phraseWrap.classList.remove("hidden");
        acceptBtn.disabled = true;
      } else {
        phraseWrap.classList.add("hidden");
        acceptBtn.disabled = false;
      }

      acceptBtn.textContent = opts.confirmLabel || "Confirm";
      acceptBtn.className =
        "btn " + (tone === "danger" ? "btn-danger-outline" : "btn-primary");
      modal.classList.remove("hidden");

      const onInput = () => {
        if (reqPhrase) {
          acceptBtn.disabled = phraseInput.value.trim() !== reqPhrase;
        }
      };

      const cleanup = (val) => {
        modal.classList.add("hidden");
        acceptBtn.disabled = false;
        acceptBtn.removeEventListener("click", onYes);
        cancelBtn.removeEventListener("click", onNo);
        phraseInput.removeEventListener("input", onInput);
        modal.removeEventListener("click", onBackdrop);
        document.removeEventListener("keydown", onKey);
        resolve(val);
      };
      const onYes = () => cleanup(true);
      const onNo = () => cleanup(false);
      const onBackdrop = (e) => {
        if (e.target === modal) cleanup(false);
      };
      const onKey = (e) => {
        if (e.key === "Escape") cleanup(false);
      };

      phraseInput.addEventListener("input", onInput);
      acceptBtn.addEventListener("click", onYes);
      cancelBtn.addEventListener("click", onNo);
      modal.addEventListener("click", onBackdrop);
      document.addEventListener("keydown", onKey);
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

  function renderKvList(container, rows, copyableKeys) {
    clearNode(container);
    const copySet = new Set(copyableKeys || []);
    rows.forEach(([k, v]) => {
      const row = document.createElement("div");
      row.className = "kv-row";
      const kEl = document.createElement("span");
      kEl.className = "kv-key";
      kEl.textContent = k;

      const wrap = document.createElement("div");
      wrap.className = "kv-val-wrap";
      const vEl = document.createElement("span");
      vEl.className = "kv-val";
      vEl.textContent = v || "-";
      wrap.appendChild(vEl);

      if (v && v !== "-" && v !== "disabled" && copySet.has(k)) {
        const cBtn = document.createElement("button");
        cBtn.type = "button";
        cBtn.className = "chip-btn";
        cBtn.textContent = "Copy";
        cBtn.addEventListener("click", () => copyText(v, k));
        wrap.appendChild(cBtn);
      }
      row.appendChild(kEl);
      row.appendChild(wrap);
      container.appendChild(row);
    });
  }

  /* ── Theme Management ── */
  function applyTheme(theme) {
    const next = theme === "light" ? "light" : "dark";
    document.documentElement.dataset.theme = next;
    try {
      window.localStorage.setItem(THEME_STORAGE_KEY, next);
    } catch (_err) {
      // ignore storage failure
    }
    const topBtn = el("theme-toggle");
    if (topBtn) topBtn.textContent = next === "dark" ? "Light" : "Dark";
    const loginBtn = el("login-theme-toggle");
    if (loginBtn) loginBtn.textContent = next === "dark" ? "Light" : "Dark";
  }

  function initTheme() {
    let saved = "";
    try {
      saved = window.localStorage.getItem(THEME_STORAGE_KEY) || "";
    } catch (_err) {
      saved = "";
    }
    if (!saved && window.matchMedia) {
      saved = window.matchMedia("(prefers-color-scheme: light)").matches
        ? "light"
        : "dark";
    }
    applyTheme(saved || "dark");
  }

  /* ── Live Task Drawer & SSE / Polling Runner ── */
  function stopJobWatchers() {
    if (state.jobStream) {
      try {
        state.jobStream.close();
      } catch (_err) {
        // ignore
      }
      state.jobStream = null;
    }
    if (state.jobPollTimer) {
      window.clearTimeout(state.jobPollTimer);
      state.jobPollTimer = null;
    }
  }

  function openTaskDrawer() {
    el("task-drawer").classList.remove("hidden");
  }

  function closeTaskDrawer() {
    el("task-drawer").classList.add("hidden");
  }

  function renderJobSnapshot(job, appendNewLines) {
    if (!job) return;
    state.activeJobId = job.id || state.activeJobId;

    el("task-title").textContent = job.title || "Operation";
    const st = job.status || "running";
    const pill = el("task-status-pill");
    pill.textContent = st;
    pill.className =
      "pill " +
      (st === "succeeded"
        ? "pill-ok"
        : st === "failed"
          ? "pill-err"
          : "pill-info");

    const pct = Number(job.progress || 0);
    el("task-stage").textContent = "Stage: " + (job.stage || st);
    el("task-pct").textContent = pct + "%";

    const bar = el("task-progress-bar");
    bar.value = pct;
    bar.className =
      "meter " +
      (st === "succeeded"
        ? "meter-ok"
        : st === "failed"
          ? "meter-err"
          : "meter-accent");

    const summaryEl = el("task-summary");
    if (job.summary && (st === "succeeded" || st === "failed")) {
      summaryEl.textContent = job.summary;
      summaryEl.className =
        "alert " + (st === "succeeded" ? "alert-ok" : "alert-error");
      summaryEl.classList.remove("hidden");
    } else {
      summaryEl.classList.add("hidden");
    }

    if (appendNewLines && Array.isArray(job.lines) && job.lines.length > 0) {
      state.jobLines = state.jobLines.concat(job.lines);
      state.jobCursor = Number(job.next_index || state.jobLines.length);
    } else if (!appendNewLines && Array.isArray(job.lines)) {
      state.jobLines = job.lines.slice();
      state.jobCursor = Number(job.next_index || state.jobLines.length);
    }

    const outEl = el("task-output");
    outEl.textContent = state.jobLines.length
      ? state.jobLines.join("\n")
      : "(waiting for output...)";
    outEl.scrollTop = outEl.scrollHeight;

    const metaParts = [];
    if (job.actor) metaParts.push("Actor: " + job.actor);
    if (job.duration_ms)
      metaParts.push((job.duration_ms / 1000).toFixed(1) + "s");
    el("task-meta").textContent = metaParts.join(" · ");

    const actBtn = el("activity-pill");
    const actLbl = el("activity-label");
    if (st === "queued" || st === "running") {
      actBtn.classList.add("is-running");
      actLbl.textContent = "Running " + pct + "%";
    } else {
      actBtn.classList.remove("is-running");
      actLbl.textContent = "Console";
    }
  }

  function finishJob(job, onComplete) {
    stopJobWatchers();
    renderJobSnapshot(job, false);
    if (job.status === "succeeded") {
      showToast(job.summary || job.title + " completed.", "ok");
    } else {
      showToast(job.summary || job.title + " failed.", "err");
    }
    if (job.meta && job.meta.new_webpanel_url) {
      showToast("WebPanel URL updated: " + job.meta.new_webpanel_url, "ok");
    }
    if (typeof onComplete === "function") {
      onComplete(job);
    }
    if (job.status === "succeeded" && job.meta && job.meta.restart_required) {
      showToast(
        "3xui-deploy updated to v" +
          (job.meta.updated_to || "latest") +
          " — reloading WebPanel...",
        "ok",
      );
      window.setTimeout(() => {
        window.location.reload();
      }, 3000);
      return;
    }
    loadActiveView();
  }

  function pollJobIncremental(jobId, onComplete) {
    stopJobWatchers();
    const tick = async () => {
      try {
        const snap = await api(
          "api/jobs/" +
            encodeURIComponent(jobId) +
            "?since=" +
            encodeURIComponent(String(state.jobCursor)),
        );
        if (snap.lines && snap.lines.length) {
          state.jobLines = state.jobLines.concat(snap.lines);
        }
        state.jobCursor = Number(snap.next_index || state.jobLines.length);
        renderJobSnapshot(
          Object.assign({}, snap, { lines: state.jobLines }),
          false,
        );
        if (snap.status === "succeeded" || snap.status === "failed") {
          finishJob(
            Object.assign({}, snap, { lines: state.jobLines }),
            onComplete,
          );
          return;
        }
      } catch (_err) {
        // Keep polling gracefully across brief Caddy restarts (e.g. certbot standalone)
      }
      state.jobPollTimer = window.setTimeout(tick, 1300);
    };
    state.jobPollTimer = window.setTimeout(tick, 900);
  }

  function watchJob(initialJob, onComplete) {
    stopJobWatchers();
    state.jobLines = Array.isArray(initialJob.lines)
      ? initialJob.lines.slice()
      : [];
    state.jobCursor = Number(initialJob.next_index || state.jobLines.length);
    renderJobSnapshot(initialJob, false);
    openTaskDrawer();

    if (initialJob.status === "succeeded" || initialJob.status === "failed") {
      finishJob(initialJob, onComplete);
      return;
    }

    if (typeof window.EventSource === "function") {
      const es = new window.EventSource(
        "./api/jobs/" + encodeURIComponent(initialJob.id) + "/stream",
      );
      state.jobStream = es;

      const handleEvent = (ev) => {
        try {
          const payload = JSON.parse(ev.data || "{}");
          if (ev.type === "state") {
            state.jobLines = Array.isArray(payload.lines)
              ? payload.lines.slice()
              : [];
            state.jobCursor = Number(
              payload.next_index || state.jobLines.length,
            );
            renderJobSnapshot(
              Object.assign({}, payload, { lines: state.jobLines }),
              false,
            );
          } else {
            if (Array.isArray(payload.lines) && payload.lines.length) {
              state.jobLines = state.jobLines.concat(payload.lines);
            }
            state.jobCursor = Number(
              payload.next_index || state.jobLines.length,
            );
            const full = Object.assign({}, payload, { lines: state.jobLines });
            renderJobSnapshot(full, false);
            if (
              ev.type === "done" ||
              payload.status === "succeeded" ||
              payload.status === "failed"
            ) {
              finishJob(full, onComplete);
            }
          }
        } catch (_err) {
          // ignore malformed chunk
        }
      };

      es.addEventListener("state", handleEvent);
      es.addEventListener("update", handleEvent);
      es.addEventListener("done", handleEvent);
      es.onerror = () => {
        es.close();
        state.jobStream = null;
        pollJobIncremental(initialJob.id, onComplete);
      };
    } else {
      pollJobIncremental(initialJob.id, onComplete);
    }
  }

  async function runOperation(path, body, opts) {
    const cfg = opts || {};
    const payload = Object.assign({}, body || {}, { async: true });
    if (cfg.button) setBusy(cfg.button, true, cfg.busyText || "Starting...");
    try {
      const res = await api(path, {
        method: cfg.method || "POST",
        body: payload,
      });
      if (res && res.accepted && res.job) {
        watchJob(res.job, cfg.onComplete);
        return res;
      }
      if (cfg.onComplete) cfg.onComplete(res);
      showToast(cfg.successMsg || "Operation completed.", "ok");
      loadActiveView();
      return res;
    } catch (err) {
      showToast(err.message, "err");
      throw err;
    } finally {
      if (cfg.button) setBusy(cfg.button, false);
    }
  }

  /* ── Navigation & Sub-tabs ── */
  function closeMobileSidebar() {
    el("sidebar").classList.remove("open");
    el("sidebar-overlay").classList.add("hidden");
  }

  function switchSubTab(groupName, targetName) {
    state.activeTabs[groupName] = targetName;
    const strip = document.querySelector(
      '.tab-strip[data-tab-group="' + groupName + '"]',
    );
    if (strip) {
      strip.querySelectorAll(".tab-btn").forEach((btn) => {
        btn.classList.toggle("active", btn.dataset.tabTarget === targetName);
      });
    }
    document
      .querySelectorAll('[data-tab-panel^="' + groupName + ':"]')
      .forEach((panel) => {
        panel.classList.toggle(
          "hidden",
          panel.dataset.tabPanel !== groupName + ":" + targetName,
        );
      });
  }

  function switchView(viewName) {
    state.currentView = viewName;
    document.querySelectorAll(".nav-item").forEach((btn) => {
      btn.classList.toggle("active", btn.dataset.view === viewName);
    });
    document.querySelectorAll(".bottom-nav-btn[data-view]").forEach((btn) => {
      btn.classList.toggle("active", btn.dataset.view === viewName);
    });
    document.querySelectorAll(".view-section").forEach((sec) => {
      sec.classList.toggle("hidden", sec.id !== "view-" + viewName);
    });
    const meta = VIEW_META[viewName] || ["Dashboard", ""];
    el("view-title").textContent = meta[0];
    el("view-subtitle").textContent = meta[1];
    closeMobileSidebar();
    loadActiveView();
  }

  function setLoggedOut() {
    stopJobWatchers();
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

  /* ── View 1: Overview / Dashboard ── */
  async function loadOverview() {
    const [data, jobsData] = await Promise.all([
      api("api/overview"),
      api("api/jobs?limit=6").catch(() => ({ jobs: [] })),
    ]);

    const summary = data.summary || {};
    const m = data.metrics || {};
    const hPill = el("hero-health-pill");
    const hs =
      summary.health_status || (data.deployed ? "healthy" : "not_deployed");
    hPill.textContent =
      hs === "healthy"
        ? "Healthy"
        : hs === "attention"
          ? "Attention Needed"
          : hs === "degraded"
            ? "Degraded"
            : "Not Deployed";
    hPill.className =
      "pill " +
      (hs === "healthy"
        ? "pill-ok"
        : hs === "attention"
          ? "pill-warn"
          : hs === "degraded"
            ? "pill-err"
            : "pill-neutral");

    el("hero-version-pill").textContent = "3x-ui " + (data.xui_tag || "--");
    el("hero-db-pill").textContent =
      "DB: " + (summary.db_backend || "unknown").toUpperCase();
    el("hero-host-meta").textContent =
      (m.os_name || "Linux") +
      (m.kernel ? " (" + m.kernel + ")" : "") +
      " · Uptime: " +
      (m.uptime || "-") +
      " · Dir: " +
      (data.install_dir || "-");

    const kpiBox = el("overview-kpis");
    clearNode(kpiBox);
    const kpiDefs = [
      {
        label: "CPU & Load",
        value: m.load_avg || "unavailable",
        sub: (m.cpu_cores || 1) + " CPU core(s) · " + (m.arch || "host"),
        pct: Math.min(
          100,
          Math.round(((m.load_1m || 0) / (m.cpu_cores || 1)) * 100),
        ),
      },
      {
        label: "Memory Usage",
        value: m.memory || "unavailable",
        sub:
          (m.mem_percent || 0) +
          "% RAM" +
          (m.swap_total_mb
            ? " · Swap " + m.swap_used_mb + "/" + m.swap_total_mb + " MiB"
            : ""),
        pct: m.mem_percent || 0,
      },
      {
        label: "Disk Usage (/)",
        value: m.disk_root || "unavailable",
        sub:
          "Backups: " +
          (summary.backup_count || 0) +
          (summary.backup_cron_enabled ? " · Cron ON" : ""),
        pct: m.disk_percent || 0,
      },
      {
        label: "Network & TLS",
        value: (m.tcp_cc || "unknown") + " / " + (m.qdisc || "unknown"),
        sub:
          (summary.certs_total || 0) +
          " cert(s) · " +
          (summary.certs_expiring || 0) +
          " expiring · " +
          (summary.certs_expired || 0) +
          " expired",
        pct: null,
      },
    ];

    kpiDefs.forEach((item) => {
      const card = document.createElement("div");
      card.className = "kpi-card";
      const l = document.createElement("div");
      l.className = "kpi-label";
      l.textContent = item.label;
      const v = document.createElement("div");
      v.className = "kpi-value";
      v.textContent = item.value;
      const s = document.createElement("div");
      s.className = "kpi-sub";
      s.textContent = item.sub;
      card.appendChild(l);
      card.appendChild(v);
      if (item.pct !== null) {
        const tone = item.pct >= 88 ? "err" : item.pct >= 72 ? "warn" : "ok";
        card.appendChild(makeMeter(item.pct, tone));
      }
      card.appendChild(s);
      kpiBox.appendChild(card);
    });

    const containers = data.containers || [];
    el("overview-container-count").textContent =
      (summary.running_containers || 0) + "/" + containers.length + " running";
    const contBox = el("overview-containers");
    clearNode(contBox);
    if (containers.length === 0) {
      const p = document.createElement("p");
      p.className = "muted";
      p.textContent = "No 3xui_* containers detected.";
      contBox.appendChild(p);
    } else {
      containers.forEach((c) => {
        const row = document.createElement("div");
        row.className = "list-item";
        const main = document.createElement("div");
        main.className = "list-item-main";
        const tRow = document.createElement("div");
        tRow.className = "list-item-title-row";
        const title = document.createElement("strong");
        title.textContent = c.name;
        tRow.appendChild(title);
        tRow.appendChild(
          makePill(c.state, c.state === "running" ? "ok" : "err"),
        );
        const meta = document.createElement("div");
        meta.className = "list-item-meta";
        const statsStr = c.cpu_perc
          ? " · CPU " + c.cpu_perc + " · MEM " + c.mem_usage
          : "";
        meta.textContent = c.image + " · " + c.status + statsStr;
        main.appendChild(tRow);
        main.appendChild(meta);
        row.appendChild(main);
        contBox.appendChild(row);
      });
    }

    renderKvList(
      el("overview-endpoints"),
      [
        ["Management URL", data.proxy.webpanel_url || "-"],
        ["Decoy Website", data.proxy.decoy_url || "-"],
        ["Subscription URL", data.proxy.sub_url || "disabled"],
        [
          "Probe Protection",
          data.probe.redirect_enabled
            ? data.probe.active_state + " -> " + data.probe.target
            : "disabled (decoy active)",
        ],
        [
          "WebPanel Bind",
          "127.0.0.1:" + data.webpanel.port + " (" + data.webpanel.path + ")",
        ],
      ],
      ["Management URL", "Decoy Website", "Subscription URL"],
    );

    const certBox = el("overview-certs");
    clearNode(certBox);
    if (!data.certs || data.certs.length === 0) {
      const p = document.createElement("p");
      p.className = "muted";
      p.textContent = "No SSL certificates detected yet.";
      certBox.appendChild(p);
    } else {
      data.certs.forEach((cert) => {
        const row = document.createElement("div");
        row.className = "list-item";
        const left = document.createElement("div");
        left.className = "list-item-main";
        const title = document.createElement("strong");
        title.textContent = cert.domain;
        const meta = document.createElement("div");
        meta.className = "list-item-meta";
        meta.textContent =
          (cert.source || "cert") +
          " · expires " +
          cert.expires +
          (cert.days_remaining !== null && cert.days_remaining !== undefined
            ? " (" + cert.days_remaining + "d)"
            : "");
        left.appendChild(title);
        left.appendChild(meta);
        row.appendChild(left);
        const tone =
          cert.status === "ok" || cert.status === "valid"
            ? "ok"
            : cert.status === "expired"
              ? "err"
              : "warn";
        row.appendChild(makePill(cert.status, tone));
        certBox.appendChild(row);
      });
    }

    const recentBox = el("overview-recent-ops");
    clearNode(recentBox);
    const jobs = jobsData.jobs || [];
    if (jobs.length === 0) {
      const p = document.createElement("p");
      p.className = "muted";
      p.textContent = "No operations recorded yet.";
      recentBox.appendChild(p);
    } else {
      jobs.forEach((j) => {
        const row = document.createElement("div");
        row.className = "list-item";
        const main = document.createElement("div");
        main.className = "list-item-main";
        const t = document.createElement("strong");
        t.textContent = j.title;
        const mEl = document.createElement("div");
        mEl.className = "list-item-meta";
        mEl.textContent =
          (j.started_at || "") + " · " + (j.summary || j.stage || "");
        main.appendChild(t);
        main.appendChild(mEl);
        row.appendChild(main);

        const right = document.createElement("div");
        right.className = "btn-row";
        const tone =
          j.status === "succeeded"
            ? "ok"
            : j.status === "failed"
              ? "err"
              : "info";
        right.appendChild(makePill(j.status, tone));
        const btn = document.createElement("button");
        btn.type = "button";
        btn.className = "btn btn-ghost btn-sm";
        btn.textContent = "Inspect";
        btn.addEventListener("click", async () => {
          const full = await api("api/jobs/" + encodeURIComponent(j.id));
          watchJob(full);
        });
        right.appendChild(btn);
        row.appendChild(right);
        recentBox.appendChild(row);
      });
    }
  }

  /* ── View 2: SSL Certificates ── */
  async function loadCerts() {
    const data = await api("api/certs");
    const statusPills = el("certs-status-pills");
    clearNode(statusPills);
    statusPills.appendChild(
      makePill(
        data.certbot_installed ? "Certbot Ready" : "Certbot Auto-Install",
        data.certbot_installed ? "ok" : "neutral",
      ),
    );
    statusPills.appendChild(
      makePill(
        data.proxy_enabled
          ? "Proxy: " + (data.panel_domain || "active")
          : "Proxy Disabled",
        data.proxy_enabled ? "info" : "neutral",
      ),
    );
    if (data.sub_domain) {
      statusPills.appendChild(makePill("Sub: " + data.sub_domain, "neutral"));
    }

    if (data.panel_domain && !el("cert-issue-domain").value) {
      el("cert-issue-domain").value = data.panel_domain;
    }

    const certs = data.certs || [];
    el("certs-count-pill").textContent = String(certs.length);
    const listBox = el("certs-list");
    clearNode(listBox);

    if (certs.length === 0) {
      const p = document.createElement("p");
      p.className = "muted";
      p.textContent = "No certificates found in cert/ or Caddy ACME store yet.";
      listBox.appendChild(p);
      return;
    }

    certs.forEach((c) => {
      const card = document.createElement("div");
      card.className = "cert-card";

      const top = document.createElement("div");
      top.className = "cert-card-top";
      const titleWrap = document.createElement("div");
      const title = document.createElement("div");
      title.className = "cert-card-title";
      title.textContent = c.domain;
      const issuer = document.createElement("div");
      issuer.className = "list-item-meta";
      issuer.textContent = "Issuer: " + (c.issuer || "unknown");
      titleWrap.appendChild(title);
      titleWrap.appendChild(issuer);
      top.appendChild(titleWrap);

      const badges = document.createElement("div");
      badges.className = "btn-row";
      const tone =
        c.status === "valid"
          ? "ok"
          : c.status === "expired"
            ? "err"
            : c.status === "expiring_soon"
              ? "warn"
              : "neutral";
      const daysLbl =
        c.days_remaining !== null && c.days_remaining !== undefined
          ? " (" + c.days_remaining + "d)"
          : "";
      badges.appendChild(makePill(c.status + daysLbl, tone));
      badges.appendChild(makePill(c.source || "cert", "neutral"));
      top.appendChild(badges);
      card.appendChild(top);

      if (c.days_remaining !== null && c.days_remaining !== undefined) {
        const pct = Math.max(
          0,
          Math.min(100, Math.round((c.days_remaining / 90) * 100)),
        );
        card.appendChild(makeMeter(pct, tone === "neutral" ? "accent" : tone));
      }

      const meta = document.createElement("div");
      meta.className = "list-item-meta";
      meta.textContent =
        "Expires: " +
        c.not_after +
        " · SANs: " +
        (c.domains || [c.domain]).join(", ") +
        (c.in_use_by && c.in_use_by.length
          ? " · Used by: " + c.in_use_by.join(", ")
          : "");
      card.appendChild(meta);

      const actions = document.createElement("div");
      actions.className = "btn-row";
      if (c.renewable) {
        const renewBtn = document.createElement("button");
        renewBtn.type = "button";
        renewBtn.className = "btn btn-ghost btn-sm";
        renewBtn.textContent = "Renew";
        renewBtn.addEventListener("click", async () => {
          const ok = await askConfirm({
            title: "Renew Certificate",
            message: "Renew Let's Encrypt certificate for " + c.domain + "?",
            bullets: [
              "Briefly stops containers so Certbot binds port 80.",
              "Reloads Caddy automatically on completion.",
            ],
            confirmLabel: "Renew Now",
          });
          if (!ok) return;
          runOperation(
            "api/certs/renew",
            { domain: c.domain },
            { button: renewBtn },
          );
        });
        actions.appendChild(renewBtn);
      }

      if (c.applicable_to_caddy) {
        const applyBtn = document.createElement("button");
        applyBtn.type = "button";
        applyBtn.className = "btn btn-ghost btn-sm";
        applyBtn.textContent = "Apply to Caddy";
        applyBtn.addEventListener("click", () => {
          runOperation(
            "api/certs/apply",
            { domain: c.domain, target: "caddy" },
            { button: applyBtn },
          );
        });
        actions.appendChild(applyBtn);
      } else if (!data.proxy_enabled && c.source !== "caddy_acme") {
        const applyPanelBtn = document.createElement("button");
        applyPanelBtn.type = "button";
        applyPanelBtn.className = "btn btn-ghost btn-sm";
        applyPanelBtn.textContent = "Apply to 3X-UI Panel";
        applyPanelBtn.addEventListener("click", () => {
          runOperation(
            "api/certs/apply",
            { domain: c.domain, target: "panel" },
            { button: applyPanelBtn },
          );
        });
        actions.appendChild(applyPanelBtn);
      }

      if (c.revocable) {
        const revokeBtn = document.createElement("button");
        revokeBtn.type = "button";
        revokeBtn.className = "btn btn-danger-outline btn-sm";
        revokeBtn.textContent = "Revoke & Delete";
        revokeBtn.addEventListener("click", async () => {
          const ok = await askConfirm({
            title: "Revoke & Delete Certificate",
            tone: "danger",
            message:
              "This permanently revokes any matching Let's Encrypt certificate and deletes " +
              c.domain +
              " from cert/.",
            bullets: [
              "If Caddy currently references this file, Caddy will safely fall back to ACME.",
              "Any 3X-UI direct webCertFile reference will be cleared.",
            ],
            requirePhrase: c.domain,
            confirmLabel: "Revoke & Delete",
          });
          if (!ok) return;
          runOperation(
            "api/certs/revoke",
            { domain: c.domain, reason: "unspecified" },
            { button: revokeBtn },
          );
        });
        actions.appendChild(revokeBtn);
      }

      if (actions.children.length > 0) {
        card.appendChild(actions);
      }
      listBox.appendChild(card);
    });
  }

  /* ── View 3: Domains & Network ── */
  function updateProxySubFieldsVisibility() {
    const mode = el("px-sub-mode").value;
    el("px-sub-fields").classList.toggle("hidden", mode === "none");
    el("px-sub-domain-wrap").classList.toggle("hidden", mode !== "dedicated");
  }

  async function loadNetwork() {
    const [net, fw] = await Promise.all([
      api("api/network"),
      api("api/network/firewall").catch(() => ({
        backend: "none",
        output: "",
      })),
    ]);

    const px = net.proxy || {};
    const panel = net.panel || {};
    const sub = net.subscription || {};
    const nw = net.network || {};

    const pxBadge = el("net-proxy-badge");
    pxBadge.textContent = px.enabled
      ? "Active (" + px.domain + ")"
      : "Disabled";
    pxBadge.className = "pill " + (px.enabled ? "pill-ok" : "pill-neutral");

    el("px-domain").value = px.domain || "";
    el("px-port").value = px.port || "443";
    el("px-email").value = px.email || "";
    el("px-sub-mode").value = px.sub_mode || "none";
    el("px-sub-domain").value = px.sub_domain || sub.domain || "";
    el("px-sub-port").value = px.sub_port || sub.port || "2096";
    el("px-sub-path").value = px.sub_path || sub.path || "/sub/";
    el("px-sub-json-path").value =
      px.sub_json_path || sub.json_path || "/json/";
    updateProxySubFieldsVisibility();

    renderKvList(
      el("net-topology-kv"),
      [
        ["Public IPv4", nw.public_ipv4 || "unavailable"],
        [
          "Panel Port / Path",
          (panel.port || "-") + " · " + (panel.path || "/"),
        ],
        ["Panel Listen IP", panel.listen_ip || "0.0.0.0 (all interfaces)"],
        ["Panel webDomain", panel.web_domain || "(unset)"],
        [
          "2FA / Session Age",
          (panel.two_factor ? "ON" : "OFF") +
            " · " +
            (panel.session_max_age || "default") +
            "m",
        ],
        ["Subscription URI", sub.uri || "(none)"],
        ["Sub JSON URI", sub.json_uri || "(none)"],
      ],
      ["Subscription URI", "Sub JSON URI"],
    );

    el("ps-port").value = panel.port || "2053";
    el("ps-session-age").value = panel.session_max_age || "60";
    el("ps-listen-ip").value = panel.listen_ip || "";
    el("ps-webpath").value = panel.path || "/";
    el("ps-webdomain").value = panel.web_domain || "";
    el("pc-user").value = panel.user || "admin";

    const subPill = el("sub-status-pill");
    subPill.textContent = sub.enable ? "Enabled" : "Disabled";
    subPill.className = "pill " + (sub.enable ? "pill-ok" : "pill-neutral");
    el("sub-enable").checked = !!sub.enable;
    el("sub-mode").value = px.enabled
      ? px.sub_mode === "same"
        ? "same"
        : "dedicated"
      : "direct";
    el("sub-domain").value = sub.domain || "";
    el("sub-listen").value = sub.listen_ip || "";
    el("sub-port").value = sub.port || "2096";
    el("sub-path").value = sub.path || "/sub/";
    el("sub-json-path").value = sub.json_path || "/json/";
    el("sub-json-enable").checked = !!sub.json_enable;
    el("sub-encrypt").checked = !!sub.encrypt;

    if (px.domain && !el("dns-check-domain").value) {
      el("dns-check-domain").value = px.domain;
    }
    const resBox = el("net-resolvers-list");
    clearNode(resBox);
    (nw.nameservers || []).forEach((ns) =>
      resBox.appendChild(makePill(ns, "neutral")),
    );
    if (!(nw.nameservers || []).length) {
      resBox.appendChild(makePill("unavailable", "neutral"));
    }
    el("net-interfaces-box").textContent =
      (nw.interfaces || []).join("\n") || "No host interface info available.";

    el("bbr-status-meta").textContent =
      "Congestion: " +
      (nw.tcp_cc || "unknown") +
      " · qdisc: " +
      (nw.qdisc || "unknown");

    el("fw-backend-pill").textContent = "Backend: " + (fw.backend || "none");
    el("firewall-output").textContent = fw.output || "No firewall output.";
  }

  /* ── View 4: Decoy & Probe ── */
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

  /* ── View 5: Inbounds & Audit ── */
  async function loadInbounds() {
    const res = await api("api/inbounds");
    el("inbounds-output").textContent = res.output || "No inbound output.";
    const box = el("inbounds-list");
    clearNode(box);
    const rows = res.rows || [];
    if (rows.length === 0) {
      const p = document.createElement("p");
      p.className = "muted";
      p.textContent =
        res.output && res.output.trim()
          ? "See raw report below for inbound details."
          : "No inbounds configured.";
      box.appendChild(p);
      return;
    }

    rows.forEach((r) => {
      const card = document.createElement("div");
      card.className = "inbound-card";
      const top = document.createElement("div");
      top.className = "inbound-top";
      const title = document.createElement("strong");
      title.textContent =
        "#" +
        r.id +
        " · " +
        r.protocol.toUpperCase() +
        (r.remark ? " (" + r.remark + ")" : "");
      const badges = document.createElement("div");
      badges.className = "btn-row";
      badges.appendChild(
        makePill(r.enabled ? "ON" : "OFF", r.enabled ? "ok" : "neutral"),
      );
      const liveTone = r.live.includes("LISTEN")
        ? "ok"
        : r.live === "DOWN"
          ? "err"
          : "warn";
      badges.appendChild(makePill(r.live, liveTone));
      top.appendChild(title);
      top.appendChild(badges);

      const meta = document.createElement("div");
      meta.className = "inbound-meta";
      meta.textContent =
        "Bind: " +
        r.listen +
        ":" +
        r.port +
        " · Transport: " +
        r.net_sec +
        " · FW: " +
        r.fw_proto +
        " · Route: " +
        r.route;
      card.appendChild(top);
      card.appendChild(meta);
      box.appendChild(card);
    });
  }

  async function runAudit() {
    const btn = el("run-audit-btn");
    setBusy(btn, true, "Auditing...");
    try {
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
    } finally {
      setBusy(btn, false);
    }
  }

  /* ── View 6: Deploy & Updates ── */
  async function loadCompatAndDeploy() {
    const [ov, data] = await Promise.all([
      api("api/overview"),
      api("api/compat"),
    ]);
    const dp = el("deploy-state-pill");
    dp.textContent = ov.deployed
      ? "Deployed (" + ov.xui_tag + ")"
      : "Not Deployed";
    dp.className = "pill " + (ov.deployed ? "pill-ok" : "pill-warn");

    const verInfo = ov.version || {};
    const deployVer = verInfo.deploy || state.version || "--";
    const vp = el("deploy-ver-pill");
    vp.textContent = "v" + deployVer;
    vp.className =
      "pill mono-num " +
      (verInfo.in_sync === false ? "pill-warn" : "pill-neutral");

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

  /* ── View 7: Backups, Logs & History ── */
  async function loadOperations() {
    const [bData, lData, jData] = await Promise.all([
      api("api/backups"),
      api(
        "api/logs?source=" +
          encodeURIComponent(el("log-source").value) +
          "&level=" +
          encodeURIComponent(el("log-level").value) +
          "&query=" +
          encodeURIComponent(el("log-query").value.trim()) +
          "&lines=200",
      ),
      api("api/jobs?limit=50"),
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
        left.className = "list-item-main";
        const title = document.createElement("strong");
        title.textContent = b.name;
        const meta = document.createElement("div");
        meta.className = "list-item-meta";
        meta.textContent =
          Math.round(b.size_bytes / 1024) + " KiB · " + b.modified_at;
        left.appendChild(title);
        left.appendChild(meta);
        row.appendChild(left);

        const restoreBtn = document.createElement("button");
        restoreBtn.type = "button";
        restoreBtn.className = "btn btn-danger-outline btn-sm";
        restoreBtn.textContent = "Restore";
        restoreBtn.addEventListener("click", async () => {
          const ok = await askConfirm({
            title: "Restore Backup Archive",
            tone: "danger",
            message:
              "Restore " + b.name + " into the active installation directory?",
            bullets: [
              "Creates a pre_restore safety archive automatically first.",
              "Replaces active database, certificates, Caddy config, and compose.yaml.",
            ],
            requirePhrase: "RESTORE",
            confirmLabel: "Restore Archive",
          });
          if (!ok) return;
          runOperation(
            "api/backups/restore",
            { name: b.name },
            { button: restoreBtn },
          );
        });
        row.appendChild(restoreBtn);
        box.appendChild(row);
      });
    }

    const cron = bData.cron || {};
    const cPill = el("backup-cron-pill");
    cPill.textContent = cron.enabled
      ? "Daily @ " + String(cron.hour || 0).padStart(2, "0") + ":00 UTC"
      : "Disabled";
    cPill.className = "pill " + (cron.enabled ? "pill-ok" : "pill-neutral");
    el("cron-enabled").checked = !!cron.enabled;
    el("cron-hour").value = cron.hour !== undefined ? cron.hour : 3;
    el("cron-keep").value = cron.keep !== undefined ? cron.keep : 7;

    el("logs-output").textContent =
      lData.lines && lData.lines.length
        ? lData.lines.join("\n")
        : lData.note || lData.error || "(empty)";

    const histBox = el("history-list");
    clearNode(histBox);
    const jobs = jData.jobs || [];
    if (jobs.length === 0) {
      const p = document.createElement("p");
      p.className = "muted";
      p.textContent = "No recorded operations yet.";
      histBox.appendChild(p);
    } else {
      jobs.forEach((j) => {
        const row = document.createElement("div");
        row.className = "list-item";
        const main = document.createElement("div");
        main.className = "list-item-main";
        const t = document.createElement("strong");
        t.textContent = j.title;
        const meta = document.createElement("div");
        meta.className = "list-item-meta";
        meta.textContent =
          (j.started_at || "") +
          " · Actor: " +
          (j.actor || "admin") +
          (j.duration_ms
            ? " · " + (j.duration_ms / 1000).toFixed(1) + "s"
            : "") +
          (j.summary ? " · " + j.summary : "");
        main.appendChild(t);
        main.appendChild(meta);
        row.appendChild(main);

        const right = document.createElement("div");
        right.className = "btn-row";
        const tone =
          j.status === "succeeded"
            ? "ok"
            : j.status === "failed"
              ? "err"
              : "info";
        right.appendChild(makePill(j.status, tone));
        const btn = document.createElement("button");
        btn.type = "button";
        btn.className = "btn btn-ghost btn-sm";
        btn.textContent = "Output";
        btn.addEventListener("click", async () => {
          const full = await api("api/jobs/" + encodeURIComponent(j.id));
          watchJob(full);
        });
        right.appendChild(btn);
        row.appendChild(right);
        histBox.appendChild(row);
      });
    }
  }

  /* ── View 8: Settings & Access ── */
  async function loadSettingsAndSessions() {
    const [ov, sessData] = await Promise.all([
      api("api/overview"),
      api("api/auth/sessions"),
    ]);
    el("wp-idle-input").value = ov.webpanel.idle_minutes || "30";
    const vInfo = ov.version || {};
    renderKvList(el("settings-summary"), [
      ["3xui-deploy Version", "v" + (vInfo.deploy || state.version || "--")],
      ["WebPanel Version", "v" + (vInfo.webpanel || state.version || "--")],
      ["Exclusive Path", ov.webpanel.path],
      ["Allowed Domain", ov.proxy.domain || state.domain],
      ["Loopback Bind", "127.0.0.1:" + ov.webpanel.port],
      ["Idle Timeout", ov.webpanel.idle_minutes + " minutes"],
    ]);

    const box = el("sessions-list");
    clearNode(box);
    (sessData.sessions || []).forEach((s) => {
      const row = document.createElement("div");
      row.className = "list-item";
      const left = document.createElement("div");
      left.className = "list-item-main";
      const title = document.createElement("strong");
      title.textContent = s.username + " (" + s.ip + ")";
      const sub = document.createElement("div");
      sub.className = "list-item-meta";
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
    if (!state.authenticated) return;
    try {
      switch (state.currentView) {
        case "overview":
          await loadOverview();
          break;
        case "certs":
          await loadCerts();
          break;
        case "network":
          await loadNetwork();
          break;
        case "probe":
          await loadProbeAndDecoy();
          break;
        case "inbounds":
          await loadInbounds();
          break;
        case "deploy":
          await loadCompatAndDeploy();
          break;
        case "operations":
          await loadOperations();
          break;
        case "settings":
          await loadSettingsAndSessions();
          break;
      }
    } catch (err) {
      showToast(err.message, "err");
    }
  }

  function generateStrongPassword() {
    const upper = "ABCDEFGHJKLMNPQRSTUVWXYZ";
    const lower = "abcdefghijkmnopqrstuvwxyz";
    const digits = "23456789";
    const syms = "!@#$%^&*-_=+";
    const all = upper + lower + digits + syms;
    const buf = new Uint32Array(20);
    window.crypto.getRandomValues(buf);
    const out = [
      upper[buf[0] % upper.length],
      lower[buf[1] % lower.length],
      digits[buf[2] % digits.length],
      syms[buf[3] % syms.length],
    ];
    for (let i = 4; i < 20; i++) {
      out.push(all[buf[i] % all.length]);
    }
    return out.join("");
  }

  function wireEvents() {
    // Login & Logout
    el("login-form").addEventListener("submit", async (e) => {
      e.preventDefault();
      el("login-error").classList.add("hidden");
      const btn = el("login-submit");
      setBusy(btn, true, "Signing in...");
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
      } finally {
        setBusy(btn, false);
      }
    });

    el("logout-btn").addEventListener("click", async () => {
      try {
        await api("api/auth/logout", { method: "POST", body: {} });
      } catch (_err) {
        // ignore error on logout
      }
      setLoggedOut();
    });

    // Show/hide password toggles
    document.querySelectorAll("[data-toggle-pw]").forEach((btn) => {
      btn.addEventListener("click", () => {
        const target = el(btn.dataset.togglePw);
        if (!target) return;
        const show = target.type === "password";
        target.type = show ? "text" : "password";
        btn.textContent = show ? "Hide" : "Show";
      });
    });

    // Navigation, Mobile Drawer, Sub-tabs, Theme
    document.querySelectorAll(".nav-item").forEach((btn) => {
      btn.addEventListener("click", () => switchView(btn.dataset.view));
    });
    document.querySelectorAll(".bottom-nav-btn[data-view]").forEach((btn) => {
      btn.addEventListener("click", () => switchView(btn.dataset.view));
    });
    document.querySelectorAll("[data-nav-jump]").forEach((btn) => {
      btn.addEventListener("click", () => switchView(btn.dataset.navJump));
    });
    el("mobile-more-btn").addEventListener("click", () => {
      el("sidebar").classList.add("open");
      el("sidebar-overlay").classList.remove("hidden");
    });
    el("sidebar-open").addEventListener("click", () => {
      el("sidebar").classList.add("open");
      el("sidebar-overlay").classList.remove("hidden");
    });
    el("sidebar-close").addEventListener("click", closeMobileSidebar);
    el("sidebar-overlay").addEventListener("click", closeMobileSidebar);
    el("refresh-view-btn").addEventListener("click", loadActiveView);

    document.querySelectorAll(".tab-strip").forEach((strip) => {
      const group = strip.dataset.tabGroup;
      strip.querySelectorAll(".tab-btn").forEach((btn) => {
        btn.addEventListener("click", () =>
          switchSubTab(group, btn.dataset.tabTarget),
        );
      });
    });

    const toggleTheme = () => {
      const next =
        document.documentElement.dataset.theme === "dark" ? "light" : "dark";
      applyTheme(next);
    };
    el("theme-toggle").addEventListener("click", toggleTheme);
    el("login-theme-toggle").addEventListener("click", toggleTheme);

    // Task Drawer Controls
    el("activity-pill").addEventListener("click", openTaskDrawer);
    el("task-close-btn").addEventListener("click", closeTaskDrawer);
    el("task-hide-btn").addEventListener("click", closeTaskDrawer);
    el("task-copy-btn").addEventListener("click", () =>
      copyText(el("task-output").textContent, "Operation output"),
    );

    // Overview Quick Backup & Lifecycle Actions
    el("hero-backup-btn").addEventListener("click", () => {
      runOperation("api/backups", {}, { button: el("hero-backup-btn") });
    });

    document.querySelectorAll("[data-lifecycle]").forEach((btn) => {
      btn.addEventListener("click", async () => {
        const action = btn.dataset.lifecycle;
        if (action === "stop" || action === "restart") {
          const ok = await askConfirm({
            title: "Confirm Stack Action",
            tone: action === "stop" ? "danger" : "warn",
            message: "Execute '" + action + "' on the 3x-ui deployment stack?",
            confirmLabel: action === "stop" ? "Stop Stack" : "Restart Stack",
          });
          if (!ok) return;
        }
        runOperation("api/lifecycle", { action }, { button: btn });
      });
    });

    // SSL Certificates
    el("certs-renew-all-btn").addEventListener("click", async () => {
      const ok = await askConfirm({
        title: "Renew All Let's Encrypt Certificates",
        message: "Run certbot renewal and reload Caddy?",
        bullets: [
          "Temporarily stops the stack so port 80 is free for ACME HTTP-01.",
          "Syncs certificates into cert/ and restarts containers.",
        ],
        confirmLabel: "Renew All",
      });
      if (!ok) return;
      runOperation(
        "api/certs/renew",
        { domain: "", force: false },
        { button: el("certs-renew-all-btn") },
      );
    });

    el("certs-force-renew-btn").addEventListener("click", async () => {
      const ok = await askConfirm({
        title: "Force Renew All Certificates",
        tone: "warn",
        message:
          "Force immediate Let's Encrypt renewal? Avoid unnecessary calls due to ACME rate limits.",
        confirmLabel: "Force Renew",
      });
      if (!ok) return;
      runOperation(
        "api/certs/renew",
        { domain: "", force: true },
        { button: el("certs-force-renew-btn") },
      );
    });

    el("cert-issue-form").addEventListener("submit", async (e) => {
      e.preventDefault();
      const dom = el("cert-issue-domain").value.trim();
      const email = el("cert-issue-email").value.trim();
      const applyMode = el("cert-issue-apply").value;
      const ok = await askConfirm({
        title: "Issue Let's Encrypt Certificate",
        message:
          "Request SSL certificate for " + dom + " via HTTP-01 standalone?",
        bullets: [
          "Ensure DNS A/AAAA for " +
            dom +
            " points to this server and port 80 is reachable.",
          "Running containers will briefly pause during challenge validation.",
        ],
        confirmLabel: "Issue Certificate",
      });
      if (!ok) return;
      runOperation("api/certs/issue", {
        domain: dom,
        email,
        apply_mode: applyMode,
      });
    });

    el("cert-self-signed-form").addEventListener("submit", (e) => {
      e.preventDefault();
      runOperation("api/certs/self-signed", {
        host: el("cert-ss-host").value.trim(),
        days: Number(el("cert-ss-days").value || 3650),
        apply_mode: el("cert-ss-apply").value,
      });
    });

    // Network, Domains & Proxy
    el("px-sub-mode").addEventListener(
      "change",
      updateProxySubFieldsVisibility,
    );
    el("px-dns-btn").addEventListener("click", async () => {
      const dom = el("px-domain").value.trim();
      if (!dom) return;
      const box = el("px-dns-result");
      try {
        const res = await api("api/network/dns-check", {
          method: "POST",
          body: { domain: dom },
        });
        box.textContent =
          "Records: " +
          ((res.records || []).join(", ") || "none") +
          " · Server IPv4: " +
          (res.server_ipv4 || "unknown") +
          (res.matched ? " (MATCH)" : " (differs or proxied)");
        box.className = "alert " + (res.matched ? "alert-ok" : "alert-info");
        box.classList.remove("hidden");
      } catch (err) {
        box.textContent = err.message;
        box.className = "alert alert-error";
        box.classList.remove("hidden");
      }
    });

    el("proxy-config-form").addEventListener("submit", async (e) => {
      e.preventDefault();
      const dom = el("px-domain").value.trim();
      const ok = await askConfirm({
        title: "Update Reverse Proxy & Domain",
        tone: "warn",
        message: "Apply Caddy reverse-proxy configuration for " + dom + "?",
        bullets: [
          "Locks 3X-UI panel to 127.0.0.1 and updates webDomain to " +
            dom +
            ".",
          "Automatic rollback triggers if Caddy rejects the generated Caddyfile.",
        ],
        confirmLabel: "Apply & Sync Caddy",
      });
      if (!ok) return;
      runOperation(
        "api/network/proxy",
        {
          domain: dom,
          port: Number(el("px-port").value || 443),
          email: el("px-email").value.trim(),
          sub_mode: el("px-sub-mode").value,
          sub_domain: el("px-sub-domain").value.trim(),
          sub_port: Number(el("px-sub-port").value || 2096),
          sub_path: el("px-sub-path").value.trim(),
          sub_json_path: el("px-sub-json-path").value.trim(),
          use_panel_cert: el("px-use-panel-cert").checked,
          use_sub_cert: el("px-use-sub-cert").checked,
        },
        { method: "PUT" },
      );
    });

    el("px-disable-btn").addEventListener("click", async () => {
      const ok = await askConfirm({
        title: "Disable Reverse Proxy & WebPanel",
        tone: "danger",
        message:
          "Stopping Caddy reverse proxy will also disable this HTTPS Web Management Panel and revert 3X-UI to direct access.",
        requirePhrase: "DISABLE",
        confirmLabel: "Disable Proxy",
      });
      if (!ok) return;
      runOperation("api/network/proxy/disable", {});
    });

    document.querySelectorAll("[data-listen-preset]").forEach((btn) => {
      btn.addEventListener("click", () => {
        el("ps-listen-ip").value = btn.dataset.listenPreset;
      });
    });

    el("ps-randomize-path-btn").addEventListener("click", async () => {
      const ok = await askConfirm({
        title: "Randomize Panel Web Base Path",
        message:
          "Generate a random 12-character base path, restart 3X-UI, and sync Caddy?",
        confirmLabel: "Randomize Path",
      });
      if (!ok) return;
      runOperation(
        "api/network/panel",
        { randomize_path: true },
        { method: "PUT" },
      );
    });

    el("panel-settings-form").addEventListener("submit", async (e) => {
      e.preventDefault();
      const ok = await askConfirm({
        title: "Apply 3X-UI Panel Settings",
        message:
          "Save updated port, listen IP, path, session timeout, and webDomain?",
        bullets: ["Restarts 3X-UI container and syncs Caddy if active."],
        confirmLabel: "Save & Restart 3X-UI",
      });
      if (!ok) return;
      runOperation(
        "api/network/panel",
        {
          port: Number(el("ps-port").value || 2053),
          listen_ip: el("ps-listen-ip").value.trim(),
          web_path: el("ps-webpath").value.trim(),
          session_max_age: Number(el("ps-session-age").value || 60),
          web_domain: el("ps-webdomain").value.trim(),
        },
        { method: "PUT" },
      );
    });

    el("pc-gen-btn").addEventListener("click", () => {
      el("pc-pass").value = generateStrongPassword();
      el("pc-pass").type = "text";
    });

    el("panel-creds-form").addEventListener("submit", async (e) => {
      e.preventDefault();
      const user = el("pc-user").value.trim();
      const pw = el("pc-pass").value;
      const ok = await askConfirm({
        title: "Update 3X-UI Panel Credentials",
        tone: "warn",
        message: "Reset 3X-UI panel admin credentials for '" + user + "'?",
        bullets: [
          "Password is transmitted via stdin and never logged.",
          "3X-UI container restarts to apply changes.",
        ],
        confirmLabel: "Update Credentials",
      });
      if (!ok) return;
      await runOperation("api/network/panel/credentials", {
        username: user,
        password: pw,
      });
      el("pc-pass").value = "";
    });

    el("pc-reset-2fa-btn").addEventListener("click", async () => {
      const ok = await askConfirm({
        title: "Reset 3X-UI Two-Factor Auth",
        tone: "danger",
        message: "Disable Two-Factor Authentication (2FA) on the 3X-UI panel?",
        confirmLabel: "Reset 2FA",
      });
      if (!ok) return;
      runOperation("api/network/panel/reset-2fa", {});
    });

    el("sub-settings-form").addEventListener("submit", (e) => {
      e.preventDefault();
      runOperation(
        "api/network/subscription",
        {
          enable: el("sub-enable").checked,
          mode: el("sub-mode").value,
          domain: el("sub-domain").value.trim(),
          listen_ip: el("sub-listen").value.trim(),
          port: Number(el("sub-port").value || 2096),
          path: el("sub-path").value.trim(),
          json_enable: el("sub-json-enable").checked,
          json_path: el("sub-json-path").value.trim(),
          encrypt: el("sub-encrypt").checked,
        },
        { method: "PUT" },
      );
    });

    el("dns-check-form").addEventListener("submit", async (e) => {
      e.preventDefault();
      const dom = el("dns-check-domain").value.trim();
      const box = el("dns-check-result");
      try {
        const res = await api("api/network/dns-check", {
          method: "POST",
          body: { domain: dom },
        });
        box.textContent =
          dom +
          " -> [" +
          ((res.records || []).join(", ") || "no records") +
          "] · Server IPv4: " +
          (res.server_ipv4 || "unknown") +
          (res.matched ? " · Exact Match" : " · Mismatch / Proxied");
        box.className = "alert " + (res.matched ? "alert-ok" : "alert-info");
        box.classList.remove("hidden");
      } catch (err) {
        box.textContent = err.message;
        box.className = "alert alert-error";
        box.classList.remove("hidden");
      }
    });

    el("apply-bbr-btn").addEventListener("click", async () => {
      const ok = await askConfirm({
        title: "Enable TCP BBR & Sysctl Tuning",
        message:
          "Write /etc/sysctl.d/99-3xui-optimizer.conf with BBR + FQ + 16MB TCP/UDP buffers?",
        confirmLabel: "Apply Tuning",
      });
      if (!ok) return;
      runOperation("api/network/bbr", {}, { button: el("apply-bbr-btn") });
    });

    el("fw-sync-btn").addEventListener("click", () => {
      runOperation(
        "api/network/firewall",
        { action: "sync" },
        { button: el("fw-sync-btn") },
      );
    });
    el("fw-refresh-btn").addEventListener("click", loadNetwork);

    el("firewall-port-form").addEventListener("submit", (e) => {
      e.preventDefault();
      runOperation("api/network/firewall", {
        action: "open",
        port: Number(el("fw-port").value),
        proto: el("fw-proto").value,
      });
    });

    el("fw-close-btn").addEventListener("click", async () => {
      const port = Number(el("fw-port").value);
      const proto = el("fw-proto").value;
      if (!port) {
        showToast("Enter a port number first.", "err");
        return;
      }
      const ok = await askConfirm({
        title: "Close Firewall Port",
        tone: "danger",
        message:
          "Remove firewall allow rule for port " + port + "/" + proto + "?",
        bullets: [
          "SSH and active Caddy proxy ports are protected against accidental lockout.",
        ],
        confirmLabel: "Close Port",
      });
      if (!ok) return;
      runOperation("api/network/firewall", { action: "close", port, proto });
    });

    // Probe & Decoy
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

    // Inbounds, Xray & Audit
    el("xray-status-btn").addEventListener("click", async () => {
      const btn = el("xray-status-btn");
      setBusy(btn, true, "Checking...");
      try {
        const res = await api("api/xray");
        const box = el("xray-status-output");
        box.textContent = res.output || "No Xray status output.";
        box.classList.remove("hidden");
      } catch (err) {
        showToast(err.message, "err");
      } finally {
        setBusy(btn, false);
      }
    });

    el("run-audit-btn").addEventListener("click", () => {
      runAudit().catch((err) => showToast(err.message, "err"));
    });

    // Deploy, Compat, Updates & Self-Update
    el("deploy-db-type").addEventListener("change", () => {
      el("deploy-pg-user-wrap").classList.toggle(
        "hidden",
        el("deploy-db-type").value !== "postgres",
      );
    });

    el("deploy-form").addEventListener("submit", async (e) => {
      e.preventDefault();
      const dbType = el("deploy-db-type").value;
      const pgUser = el("deploy-pg-user").value.trim() || "xui";
      const ok = await askConfirm({
        title: "Deploy / Redeploy 3X-UI Stack",
        tone: "warn",
        message: "Generate compose.yaml (" + dbType + ") and start containers?",
        bullets: [
          "If already deployed, compose.yaml will be overwritten (existing db/ & cert/ data are preserved).",
        ],
        confirmLabel: "Deploy Stack",
      });
      if (!ok) return;
      runOperation("api/deploy", { db_type: dbType, pg_user: pgUser });
    });

    el("check-self-update-btn").addEventListener("click", async () => {
      const btn = el("check-self-update-btn");
      const box = el("self-update-status");
      setBusy(btn, true, "Checking...");
      try {
        const res = await api("api/version?check=1");
        const cur = res.current_version || state.version || "--";
        const latest = res.latest_version || "unknown";
        const ref = res.latest_ref || "main";
        const chan = res.channel || "main";
        if (res.update_available === true) {
          box.textContent =
            "Update available: v" +
            cur +
            " -> v" +
            latest +
            " (" +
            chan +
            ": " +
            ref +
            ")";
          box.className = "alert alert-info";
        } else if (res.update_available === false) {
          box.textContent =
            "Up to date on v" + cur + " (" + chan + ": " + ref + ")";
          box.className = "alert alert-ok";
        } else {
          box.textContent =
            "Current v" + cur + " · Remote version unavailable.";
          box.className = "alert alert-info";
        }
        box.classList.remove("hidden");
      } catch (err) {
        box.textContent = err.message;
        box.className = "alert alert-error";
        box.classList.remove("hidden");
      } finally {
        setBusy(btn, false);
      }
    });

    el("self-update-form").addEventListener("submit", async (e) => {
      e.preventDefault();
      const target = el("self-update-target").value.trim();
      const force = el("self-update-force").checked;
      const ok = await askConfirm({
        title: "Update 3xui-deploy",
        message:
          "Download, checksum-verify, and apply " +
          (target || "the latest GitHub release") +
          "?",
        bullets: [
          "Updates manage.sh, global CLI, and all installed WebPanel files.",
          "If the WebPanel service restarts, the page will reload automatically.",
        ],
        confirmLabel: "Update 3xui-deploy",
      });
      if (!ok) return;
      runOperation(
        "api/self-update",
        { target, force },
        { button: el("self-update-btn") },
      );
    });

    el("compat-refresh-btn").addEventListener("click", loadCompatAndDeploy);

    el("compat-test-form").addEventListener("submit", (e) => {
      e.preventDefault();
      const tag = el("compat-test-tag").value.trim();
      runOperation("api/compat/test", { tag });
    });

    el("update-form").addEventListener("submit", async (e) => {
      e.preventDefault();
      const tag = el("update-tag-input").value.trim();
      const force = el("update-force-compat").checked;
      const ok = await askConfirm({
        title: "Confirm 3x-ui Update",
        tone: force ? "danger" : "warn",
        message:
          "Pull and apply " +
          (tag || "latest release") +
          "? Automatic rollback is enabled if verification fails.",
        confirmLabel: "Pull & Update",
      });
      if (!ok) return;
      runOperation("api/update", { tag: tag || null, force_compat: force });
    });

    el("rollback-btn").addEventListener("click", async () => {
      const ok = await askConfirm({
        title: "Confirm Version Rollback",
        tone: "danger",
        message: "Restore compose.yaml.bak and recreate previous containers?",
        confirmLabel: "Rollback Now",
      });
      if (!ok) return;
      runOperation("api/rollback", {}, { button: el("rollback-btn") });
    });

    // Backups, Cron, GeoIP, Logs & History
    el("create-backup-btn").addEventListener("click", () => {
      runOperation("api/backups", {}, { button: el("create-backup-btn") });
    });

    el("prune-form").addEventListener("submit", async (e) => {
      e.preventDefault();
      const keep = Number(el("prune-keep").value || 7);
      const ok = await askConfirm({
        title: "Prune Old Backups",
        tone: "warn",
        message: "Keep only the newest " + keep + " backup archives?",
        confirmLabel: "Prune Archives",
      });
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
        loadOperations();
      } catch (err) {
        showToast(err.message, "err");
      }
    });

    el("backup-cron-form").addEventListener("submit", async (e) => {
      e.preventDefault();
      try {
        await api("api/backups/cron", {
          method: "PUT",
          body: {
            enabled: el("cron-enabled").checked,
            hour: Number(el("cron-hour").value || 3),
            keep: Number(el("cron-keep").value || 7),
          },
        });
        showToast("Backup cron schedule updated.", "ok");
        loadOperations();
      } catch (err) {
        showToast(err.message, "err");
      }
    });

    document.querySelectorAll("[data-geo]").forEach((btn) => {
      btn.addEventListener("click", async () => {
        const scope = btn.dataset.geo;
        const ok = await askConfirm({
          title: "Update GeoIP/GeoSite",
          message: "Download '" + scope + "' geo datasets and restart Xray?",
          confirmLabel: "Update GeoIP",
        });
        if (!ok) return;
        runOperation("api/geo-update", { scope }, { button: btn });
      });
    });

    el("logs-refresh-btn").addEventListener("click", () => {
      loadOperations().catch((err) => showToast(err.message, "err"));
    });
    el("log-source").addEventListener("change", () => {
      loadOperations().catch((err) => showToast(err.message, "err"));
    });
    el("log-level").addEventListener("change", () => {
      loadOperations().catch((err) => showToast(err.message, "err"));
    });
    el("log-query").addEventListener("keydown", (e) => {
      if (e.key === "Enter") {
        e.preventDefault();
        loadOperations().catch((err) => showToast(err.message, "err"));
      }
    });
    el("health-diag-btn").addEventListener("click", async () => {
      const btn = el("health-diag-btn");
      setBusy(btn, true, "Running...");
      try {
        const res = await api("api/health");
        el("logs-output").textContent = res.output || "No health output.";
        showToast("System health snapshot loaded.", "ok");
      } catch (err) {
        showToast(err.message, "err");
      } finally {
        setBusy(btn, false);
      }
    });
    el("history-refresh-btn").addEventListener("click", () => {
      loadOperations().catch((err) => showToast(err.message, "err"));
    });

    // Settings & Sessions
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

    el("webpanel-settings-form").addEventListener("submit", async (e) => {
      e.preventDefault();
      try {
        const idleMin = Number(el("wp-idle-input").value || 30);
        await api("api/webpanel/settings", {
          method: "PUT",
          body: { idle_minutes: idleMin },
        });
        showToast("Session idle timeout updated.", "ok");
        loadSettingsAndSessions();
      } catch (err) {
        showToast(err.message, "err");
      }
    });

    el("revoke-others-btn").addEventListener("click", async () => {
      const ok = await askConfirm({
        title: "Revoke Other Sessions",
        tone: "danger",
        message: "Sign out all other active browser sessions?",
        confirmLabel: "Revoke Sessions",
      });
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
    initTheme();
    wireEvents();
    try {
      const status = await api("api/auth/status");
      state.domain = status.domain || window.location.hostname;
      state.basePath = status.base_path || "/deploy/";
      state.version = status.version || "";
      if (state.version) {
        el("login-version").textContent = "v" + state.version;
        el("sidebar-version").textContent = "v" + state.version;
      }
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
