    const runtimeApi = "/cgi-bin/xray-admin";
    const vpsApi = "/cgi-bin/xray-vps";
    const rulesApi = "/cgi-bin/xray-rules";
    const state = {
      runtime: null,
      vps: null,
      rules: null,
      formDirty: false,
      rulesDirty: false,
      rulesConfigDirty: false,
      pendingRulesMode: "",
      pendingRulesPreviousMode: "",
      rulesEditorBaseHead: "",
      rulesTextLoaded: false,
      rulesTextChecksum: "",
      refreshBusy: false,
      rulesBusy: false,
      logsBusy: false,
      foregroundBusy: false,
      uiReady: false,
      rulesJobPollTimer: 0,
      repairRunning: false
    };

    const compareFields = [
      { key: "server_address", label: "VPS Host / Address", routerKey: "server_address", remoteKey: null },
      { key: "server_port", label: "Server Port", routerKey: "server_port", remoteKey: "server_port" },
      { key: "server_name", label: "Server Name / SNI", routerKey: "server_name", remoteKey: "server_name" },
      { key: "uuid", label: "UUID", routerKey: "uuid", remoteKey: "uuid" },
      { key: "public_key", label: "Reality Public Key", routerKey: "public_key", remoteKey: "public_key" },
      { key: "short_id", label: "Short ID", routerKey: "short_id", remoteKey: "short_id" },
      { key: "flow", label: "Flow", routerKey: "flow", remoteKey: "flow" }
    ];

    function flash(message, kind = "good") {
      const box = document.getElementById("flash");
      box.textContent = message;
      box.className = `flash show ${kind}`;
    }

    function flashLoading(message) {
      const box = document.getElementById("flash");
      box.textContent = message;
      box.className = "flash show info loading";
    }

    function clearFlash() {
      const box = document.getElementById("flash");
      box.className = "flash";
      box.textContent = "";
    }

    function statusText(enabled, onLabel = "running", offLabel = "stopped") {
      return enabled ? onLabel : offLabel;
    }

    function applyState(el, enabled, onLabel, offLabel) {
      el.textContent = statusText(enabled, onLabel, offLabel);
      el.className = `value ${enabled ? "ok" : "bad"}`;
    }

    function setBusy(button, busy) {
      if (button) {
        button.disabled = busy;
      }
    }

    function setControlsBusy(busy) {
      state.foregroundBusy = busy;
      [
        "profileSelect",
        "vpsProfile",
        "createProfileBtn",
        "diagnoseRepairBtn",
        "smokeBtn",
        "logsBtn",
        "rulesModeToggle",
        "rulesSaveConfigBtn",
        "rulesApplyBtn",
        "rulesPullBtn",
        "rulesPushBtn",
        "rulesGitSyncEnabled",
        "rulesEnablePush",
        "rulesRepoFetchUrl",
        "rulesRepoPushUrl",
        "rulesRepoBranch",
        "rulesSyncInterval",
        "rulesGitAuthMode",
        "rulesGitHttpUsername",
        "rulesGitHttpPassword",
        "rulesGitSshPrivateKey",
        "rulesExternalEnabled",
        "rulesExternalUrl",
        "rulesExternalInterval",
        "rulesExternalPreviewBtn",
        "rulesExternalRunBtn",
        "rulesLoadTextBtn",
        "rulesText"
      ].forEach((id) => {
        const el = document.getElementById(id);
        if (el) {
          el.disabled = busy;
        }
      });
    }

    function setStartupControlsDisabled(disabled) {
      [
        "profileSelect",
        "vpsProfile",
        "createProfileBtn",
        "diagnoseRepairBtn",
        "smokeBtn",
        "rulesModeToggle",
        "rulesSaveConfigBtn",
        "rulesApplyBtn",
        "rulesPullBtn",
        "rulesPushBtn",
        "rulesGitSyncEnabled",
        "rulesEnablePush",
        "rulesRepoFetchUrl",
        "rulesRepoPushUrl",
        "rulesRepoBranch",
        "rulesSyncInterval",
        "rulesGitAuthMode",
        "rulesGitHttpUsername",
        "rulesGitHttpPassword",
        "rulesGitSshPrivateKey",
        "rulesExternalEnabled",
        "rulesExternalUrl",
        "rulesExternalInterval",
        "rulesExternalPreviewBtn",
        "rulesExternalRunBtn",
        "rulesLoadTextBtn",
        "rulesText"
      ].forEach((id) => {
        const el = document.getElementById(id);
        if (el) {
          el.disabled = disabled;
        }
      });
    }

    const RULES_MODE_TIMEOUT_MS = 160000;
    const RULES_SAVE_CONFIG_TIMEOUT_MS = 70000;
    const RULES_SYNC_TIMEOUT_MS = 190000;
    const RULES_EXTERNAL_PREVIEW_TIMEOUT_MS = 370000;
    const RULES_EXTERNAL_VALIDATE_TIMEOUT_MS = 95000;
    const RULES_EXTERNAL_RUN_TIMEOUT_MS = 610000;
    const RULES_STATUS_TIMEOUT_MS = 12000;
    const RULES_TEXT_TIMEOUT_MS = 45000;
    const RULES_TEXT_AUTOLOAD_SOURCE_LIMIT = 2000;
    const RULES_JOB_STATUS_DELAY_MS = 2000;
    const RULES_JOB_POLL_MS = 2000;

    function beginForegroundTask(message, pauseMs = 15000) {
      setControlsBusy(true);
      flashLoading(message);
    }

    function endForegroundTask() {
      setControlsBusy(false);
    }

    function parseDiffList(text) {
      return (text || "").split(",").map((item) => item.trim()).filter(Boolean);
    }

    function sleep(ms) {
      return new Promise((resolve) => window.setTimeout(resolve, ms));
    }

    function escapeHtml(value) {
      return String(value || "")
        .replaceAll("&", "&amp;")
        .replaceAll("<", "&lt;")
        .replaceAll(">", "&gt;")
        .replaceAll('"', "&quot;");
    }

    async function callApi(base, action = "status", payload = null, options = {}) {
      const timeoutMs = options.timeoutMs || 8000;
      const controller = new AbortController();
      const timer = setTimeout(() => controller.abort(), timeoutMs);
      let response;
      try {
        if (payload) {
          const body = new URLSearchParams({ action, ...payload });
          response = await fetch(base, {
            method: "POST",
            credentials: "same-origin",
            cache: "no-store",
            headers: { "Content-Type": "application/x-www-form-urlencoded;charset=UTF-8" },
            body,
            signal: controller.signal
          });
        } else {
          response = await fetch(`${base}?action=${encodeURIComponent(action)}`, {
            method: "GET",
            credentials: "same-origin",
            cache: "no-store",
            signal: controller.signal
          });
        }
        const text = await response.text();
        try {
          return JSON.parse(text);
        } catch (err) {
          throw new Error(`Invalid JSON from ${base}: ${text.slice(0, 300)}`);
        }
      } catch (err) {
        if (err.name === "AbortError") {
          throw new Error(`Request timeout after ${Math.round(timeoutMs / 1000)}s`);
        }
        throw err;
      } finally {
        clearTimeout(timer);
      }
    }

    function activeProfile() {
      if (!state.vps || !Array.isArray(state.vps.profiles)) {
        return null;
      }
      return state.vps.profiles.find((item) => item.id === state.vps.active_profile_id) || state.vps.profiles[0] || null;
    }

    function formProfileId() {
      return document.getElementById("profileId").value.trim();
    }

    function formPayload() {
      const host = document.getElementById("vpsHost").value.trim();
      return {
        profile_id: document.getElementById("profileId").value.trim(),
        label: document.getElementById("profileLabel").value.trim(),
        vps_profile: document.getElementById("vpsProfile").value,
        auth_mode: document.getElementById("authMode").value,
        ssh_host: host,
        ssh_port: document.getElementById("sshPort").value.trim(),
        ssh_user: document.getElementById("sshUser").value.trim(),
        ssh_password: document.getElementById("sshPassword").value,
        server_address: host,
        server_port: document.getElementById("serverPort").value.trim(),
        server_name: document.getElementById("serverName").value.trim(),
        uuid: document.getElementById("uuid").value.trim(),
        public_key: document.getElementById("publicKey").value.trim(),
        short_id: document.getElementById("shortId").value.trim(),
        flow: document.getElementById("flow").value.trim(),
        bootstrap_private_key: document.getElementById("bootstrapKey").value.trim()
      };
    }

    function markDirty() {
      state.formDirty = true;
    }

    function clearDirty() {
      state.formDirty = false;
    }

    function markRulesDirty() {
      state.rulesDirty = true;
      updateRulesActionState();
    }

    function clearRulesDirty() {
      state.rulesDirty = false;
      updateRulesActionState();
    }

    function markRulesConfigDirty() {
      state.rulesConfigDirty = true;
      updateRulesConfigUi();
    }

    function clearRulesConfigDirty() {
      state.rulesConfigDirty = false;
      updateRulesConfigUi();
    }

    function currentExternalSourceSelection() {
      const selected = {};
      document.querySelectorAll('input[name="rulesExternalSourceEnabled"]').forEach((input) => {
        selected[input.dataset.sourceId] = input.checked;
      });
      return selected;
    }

    function selectedExternalSourceIds() {
      return Array.from(document.querySelectorAll('input[name="rulesExternalSourceEnabled"]:checked'))
        .map((input) => input.dataset.sourceId)
        .filter(Boolean);
    }

    function externalSourceById(sourceId) {
      return (Array.isArray(state.rules?.external_sources) ? state.rules.external_sources : [])
        .find((item) => item.id === sourceId) || null;
    }

    function showRulesTextModal(title, meta, body) {
      document.getElementById("rulesTextModalTitle").textContent = title || "Managed Source";
      document.getElementById("rulesTextModalMeta").textContent = meta || "";
      document.getElementById("rulesTextModalBody").textContent = body || "(empty)";
      const modal = document.getElementById("rulesTextModal");
      modal.classList.add("show");
      modal.setAttribute("aria-hidden", "false");
    }

    function hideRulesTextModal() {
      const modal = document.getElementById("rulesTextModal");
      modal.classList.remove("show");
      modal.setAttribute("aria-hidden", "true");
    }

    function renderExternalSources(sources, selectionOverride = {}) {
      const container = document.getElementById("rulesExternalSources");
      if (!container) {
        return;
      }
      const sourceList = Array.isArray(sources) ? sources : [];
      const html = sourceList.map((source) => {
        const enabled = Object.prototype.hasOwnProperty.call(selectionOverride, source.id)
          ? !!selectionOverride[source.id]
          : !!source.enabled;
        const health = source.health || "unknown";
        const lastSync = source.last_run_at ? formatUnixTime(source.last_run_at) : "never";
        const storedInfo = source.file_present ? `${source.file_count || 0} targets` : "no file";
        const errorLine = (health === "error" && source.last_message)
          ? `<div class="source-error-inline">Last fetch failed: ${escapeHtml(source.last_message)}</div>`
          : "";
        return `
          <div class="external-source-card">
            <div class="subhead" style="align-items:flex-start;margin-bottom:0;">
              <div style="flex:1 1 auto;">
                <div style="display:flex;align-items:center;gap:6px;margin-bottom:4px;">
                  <span style="font-weight:700;">${escapeHtml(source.label || source.id)}</span>
                  <span style="font-size:11px;color:var(--muted);margin-left:4px;">${escapeHtml(storedInfo)} · ${escapeHtml(lastSync)}</span>
                </div>
                <div style="font-size:12px;color:var(--muted);font-family:monospace;">${escapeHtml(source.url || "")}</div>
                ${errorLine}
              </div>
              <div class="toggle-row" style="justify-content:flex-end;">
                <span class="toggle-label">Apply</span>
                <label class="toggle-switch" for="rulesExternalEnable_${escapeHtml(source.id)}">
                  <input
                    type="checkbox"
                    id="rulesExternalEnable_${escapeHtml(source.id)}"
                    name="rulesExternalSourceEnabled"
                    class="rules-external-enable-input"
                    data-source-id="${escapeHtml(source.id)}"
                    ${enabled ? "checked" : ""}
                    aria-label="Apply managed source ${escapeHtml(source.label || source.id)}"
                  >
                  <span class="toggle-slider"></span>
                </label>
              </div>
            </div>
            <div class="external-source-actions">
              <button class="rules-external-download-stored-btn" data-source-id="${escapeHtml(source.id)}">Download Stored</button>
              <button class="rules-external-download-fresh-btn" data-source-id="${escapeHtml(source.id)}">Download Fresh</button>
              <button class="rules-external-edit-btn" data-source-id="${escapeHtml(source.id)}">Edit</button>
            </div>
          </div>
        `;
      }).join("");
      container.innerHTML = html || '<div class="readonly-pane">No managed external sources are available on this router.</div>';
    }

    function backendPendingRulesMode(data = state.rules) {
      if (data?.ui_job_state === "running" && data?.ui_job_kind === "set_mode" && data?.ui_job_target_mode) {
        return data.ui_job_target_mode;
      }
      return "";
    }

    function rulesJobIsRunning(data = state.rules) {
      return data?.ui_job_state === "running";
    }

    function formatRulesJobFailureDetails(data, fallbackMessage) {
      const lines = [data?.ui_job_message || fallbackMessage || "Router operation failed."];
      if (data?.ui_job_suggestion) {
        lines.push("", `Suggestion: ${data.ui_job_suggestion}`);
      }
      if (data?.ui_job_console_output) {
        lines.push("", "Console output:", data.ui_job_console_output);
      }
      return lines.join("\n");
    }

    function buildRulesJobError(label, data) {
      const error = new Error(data?.ui_job_message || data?.sync_phase_message || `${label} failed on the router.`);
      error.routerJob = data;
      return error;
    }

    function ensureRulesJobPolling(data = state.rules) {
      if (state.rulesJobPollTimer) {
        clearTimeout(state.rulesJobPollTimer);
        state.rulesJobPollTimer = 0;
      }
      if (!rulesJobIsRunning(data)) {
        return;
      }
      state.rulesJobPollTimer = window.setTimeout(() => {
        state.rulesJobPollTimer = 0;
        refreshRules(false, true).catch(() => {});
      }, RULES_JOB_POLL_MS);
    }

    function effectiveRulesMode(data = state.rules) {
      return state.pendingRulesMode || backendPendingRulesMode(data) || data?.xray_mode || "full";
    }

