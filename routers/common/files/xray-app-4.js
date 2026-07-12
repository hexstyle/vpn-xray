    function updateRulesConfigUi() {
      const syncEnabled = !!document.getElementById("rulesGitSyncEnabled")?.checked;
      const authMode = document.getElementById("rulesGitAuthMode")?.value || "none";
      const repoUrl = document.getElementById("rulesRepoFetchUrl")?.value.trim() || "";
      const pushEnabled = !!document.getElementById("rulesEnablePush")?.checked;
      const enabledSourceIds = selectedExternalSourceIds();
      const syncFieldsWrap = document.getElementById("rulesGitConfigFields");
      const httpsWrap = document.getElementById("rulesGitHttpsFields");
      const sshWrap = document.getElementById("rulesGitSshKeyWrap");
      const saveButton = document.getElementById("rulesSaveConfigBtn");
      const gitConfigured = !!state.rules?.git_configured;
      const sshHint = document.getElementById("rulesGitSshHint");
      const syncHint = document.getElementById("rulesGitSyncHint");
      const syncStateText = document.getElementById("rulesGitSyncStateText");
      const pushStateText = document.getElementById("rulesPushStateText");
      const pushHint = document.getElementById("rulesPushHint");
      const usernameInput = document.getElementById("rulesGitHttpUsername");
      const passwordInput = document.getElementById("rulesGitHttpPassword");
      const sshKeyInput = document.getElementById("rulesGitSshPrivateKey");
      const externalIntervalInput = document.getElementById("rulesExternalInterval");
      const externalRunButton = document.getElementById("rulesExternalRunBtn");
      const externalHint = document.getElementById("rulesExternalHint");
      const backendJobRunning = rulesJobIsRunning(state.rules);
      const readonlyAuth = authMode === "readonly" || authMode === "none";
      const projectedReadonly = rulesGitReadonlyProjected();
      const externalJobRunning = backendJobRunning && state.rules?.ui_job_kind === "sync_external_source";

      if (syncFieldsWrap) {
        syncFieldsWrap.style.display = syncEnabled ? "" : "none";
      }
      if (httpsWrap) {
        httpsWrap.style.display = syncEnabled && authMode === "https" ? "" : "none";
      }
      if (sshWrap) {
        sshWrap.style.display = syncEnabled && authMode === "ssh" ? "" : "none";
      }
      if (saveButton) {
        // Settings save is deliberately separate from the list's "Save & Sync
        // List". With Git on, saving also checks the repo is reachable and has
        // the shared list, so the label says "& Check"; local-only has nothing
        // remote to check.
        saveButton.textContent = !syncEnabled
          ? "Save Settings (Local-Only)"
          : (projectedReadonly ? "Save & Check Settings (Pull-Only)" : "Save & Check Settings");
      }
      if (pushStateText) {
        if (!syncEnabled) {
          pushStateText.textContent = "Push unused while Git sync is disabled.";
          pushStateText.className = "toggle-state";
        } else if (state.rulesConfigDirty) {
          pushStateText.textContent = pushEnabled
            ? "Push will be attempted after write auth is saved."
            : "Push will stay disabled after save.";
          pushStateText.className = `toggle-state ${pushEnabled ? "warn" : ""}`;
        } else if (state.rules?.git_push_ready) {
          pushStateText.textContent = "Push is ready.";
          pushStateText.className = "toggle-state ok";
        } else {
          pushStateText.textContent = state.rules?.git_push_message || "Push is not ready.";
          pushStateText.className = "toggle-state warn";
        }
      }
      if (pushHint) {
        pushHint.textContent = !syncEnabled
          ? "Git push is not used in local-only mode."
          : state.rulesConfigDirty
          ? (pushEnabled
            ? "After save, Push also needs writable HTTPS token or SSH deploy-key access. The status panel below will show the exact blocker."
            : "Pull/apply will stay available, but Push To Git will remain disabled.")
          : rulesGitPushActionText(state.rules);
      }
      if (sshHint) {
        sshHint.textContent = !syncEnabled
          ? "SSH key settings stay unused until Git sync is enabled."
          : readonlyAuth
          ? "Pull-only Git mode does not use an SSH key on the router."
          : authMode === "ssh"
          ? "Paste a private key only if you want to replace the router's stored git SSH key. Otherwise the existing/generated key stays in place."
          : "SSH key replacement is only used when Git Auth is set to SSH.";
      }
      if (syncHint) {
        syncHint.textContent = syncEnabled
          ? (projectedReadonly
            ? "When enabled in pull/apply mode, the router pulls the configured remote rules file. Local editing and Apply stay available, but Push requires the separate Allow Push setting and write credentials."
            : "When enabled, the router checks that the configured remote rules file exists before saving the sync settings.")
          : "With Git sync disabled, the router uses only the local text list below and never pulls from Git.";
      }
      if (syncStateText && state.rulesConfigDirty) {
        syncStateText.textContent = !syncEnabled
          ? "Git sync will stay disabled after save."
          : (projectedReadonly ? "Pull-only Git sync will be enabled after save." : "Git sync will be enabled after save.");
        syncStateText.className = `toggle-state ${syncEnabled ? "warn" : ""}`;
      }
      if (usernameInput) {
        usernameInput.disabled = !syncEnabled || authMode !== "https" || state.foregroundBusy;
      }
      if (passwordInput) {
        const hasStoredSecret = !!state.rules?.git_http_password_set;
        passwordInput.disabled = !syncEnabled || authMode !== "https" || state.foregroundBusy;
        passwordInput.placeholder = hasStoredSecret
          ? "Leave blank to keep the stored secret"
          : "Optional token or password";
      }
      if (sshKeyInput) {
        sshKeyInput.disabled = !syncEnabled || authMode !== "ssh" || state.foregroundBusy;
      }
      const enablePushInput = document.getElementById("rulesEnablePush");
      if (enablePushInput) {
        enablePushInput.disabled = !syncEnabled || state.foregroundBusy || backendJobRunning;
      }
      if (externalIntervalInput) {
        externalIntervalInput.disabled = state.foregroundBusy || backendJobRunning || enabledSourceIds.length === 0;
      }
      if (externalRunButton) {
        externalRunButton.textContent = externalJobRunning ? "Refresh Running..." : "Refresh Managed Snapshots Now";
        externalRunButton.disabled = enabledSourceIds.length === 0 || state.foregroundBusy || backendJobRunning;
        externalRunButton.title = externalJobRunning
          ? (state.rules?.ui_job_message || "The router is still refreshing managed source files.")
          : "";
      }
      document.querySelectorAll(".rules-external-enable-input").forEach((input) => {
        input.disabled = state.foregroundBusy || backendJobRunning;
      });
      document.querySelectorAll(".rules-external-download-fresh-btn").forEach((button) => {
        button.disabled = state.foregroundBusy;
      });
      document.querySelectorAll(".rules-external-download-stored-btn").forEach((button) => {
        const source = externalSourceById(button.dataset.sourceId || "");
        button.disabled = state.foregroundBusy || !source?.file_present;
      });
      document.querySelectorAll(".rules-external-edit-btn").forEach((button) => {
        button.disabled = state.foregroundBusy;
      });
      if (externalHint) {
        if (externalJobRunning) {
          externalHint.textContent = `Managed source refresh is running on the router. Preview and stored-file viewing stay available while the refresh job works in the background. ${state.rules?.ui_job_message || ""}`.trim();
        } else if (projectedReadonly) {
          externalHint.textContent = "Managed source preview and viewing stay available in pull-only Git mode. Snapshot refresh is still allowed because it only updates the router-local stored files, not the upstream Git rules file.";
        } else if (!enabledSourceIds.length) {
          externalHint.textContent = "Background refresh can keep stored managed snapshots current, but none of them currently join the effective routing ruleset because every Apply toggle is off.";
        } else {
          externalHint.textContent = gitConfigured
            ? "Managed source snapshots refresh in the background on the router no more often than the configured interval. The Apply toggles only decide which stored snapshots join the effective routing ruleset."
            : "Managed source snapshots refresh locally in the background on the router no more often than the configured interval. The Apply toggles only decide which stored snapshots join the effective routing ruleset.";
        }
      }
    }

    async function waitForRulesJob(label, timeoutMs, expectedJobId = "") {
      const startedAt = Date.now();
      const deadline = startedAt + timeoutMs;
      let nextDelay = RULES_JOB_STATUS_DELAY_MS;

      while (Date.now() < deadline) {
        await sleep(nextDelay);
        nextDelay = RULES_JOB_POLL_MS;
        const data = await callApi(
          rulesApi,
          "status",
          { include_rules_text: "0" },
          { timeoutMs: RULES_STATUS_TIMEOUT_MS }
        );
        // A busy/error response carries no real job state — skip it instead of
        // poisoning the render (which would flash a false mode/list).
        if (data && data.ok === false) {
          continue;
        }
        state.rules = data;
        renderRules(data);

        if (expectedJobId && data.ui_job_id && data.ui_job_id !== expectedJobId) {
          return data;
        }
        if (data.ui_job_state === "running") {
          flashLoading(`${label}... ${data.ui_job_message || data.sync_phase_message || "Still working on the router."}`);
          continue;
        }
        if (data.ui_job_state === "error") {
          throw buildRulesJobError(label, data);
        }
        return data;
      }

      throw new Error(`${label} is still not finished. Last router status: ${state.rules?.ui_job_message || state.rules?.sync_phase_message || "no final state yet"}`);
    }

    // Poll the fast, lock-free mode probe until the router CONFIRMS the target
    // mode with the set_mode job finished (or throw on failure/timeout). The
    // immediate set_mode response's job state can be stale (the previous run's
    // "success") before the new job registers as running — trusting it made the
    // toggle bounce back to the old mode mid-apply. Confirming against
    // mode_status (a few ms) also lets the UI observe completion quickly instead
    // of waiting on 3.5s full-status polls.
    async function confirmRulesMode(target, timeoutMs) {
      const deadline = Date.now() + timeoutMs;
      await sleep(RULES_JOB_STATUS_DELAY_MS);
      while (Date.now() < deadline) {
        let data = null;
        try {
          data = await callApi(rulesApi, "mode_status", null, { timeoutMs: RULES_STATUS_TIMEOUT_MS });
        } catch (err) {
          data = null;
        }
        if (data && data.ok !== false && data.xray_mode) {
          state.rulesModeQuick = data;
          renderRulesModeUi(state.rules);
          const jobRunning = data.ui_job_state === "running";
          if (!jobRunning && (data.ui_job_state === "error" || data.ui_job_state === "failed")
              && data.ui_job_target_mode === target && data.xray_mode !== target) {
            throw new Error("router reported the mode change failed");
          }
          if (!jobRunning && data.xray_mode === target) {
            return data;
          }
          flashLoading(`Applying ${target} routing mode... still working on the router.`);
        }
        await sleep(RULES_JOB_POLL_MS);
      }
      throw new Error(`${target} routing mode did not confirm in time`);
    }

    async function setRulesMode(mode, input) {
      state.pendingRulesPreviousMode = state.rules?.xray_mode
        || state.rulesModeQuick?.xray_mode
        || (mode === "selective" ? "full" : "selective");
      state.pendingRulesMode = mode;
      // Pin the toggle to the TARGET immediately and keep it there (disabled,
      // "Applying...") until the router confirms — no bounce-back.
      renderRulesModeUi(state.rules);
      updateRulesActionState();
      beginForegroundTask(`Applying ${mode} routing mode with hard cutover...`, RULES_MODE_TIMEOUT_MS, "rules");
      setBusy(input, true);
      try {
        const start = await callApi(rulesApi, "set_mode", { mode }, { timeoutMs: RULES_STATUS_TIMEOUT_MS });
        if (start && start.ok === false) {
          throw new Error(start.error || "backend error");
        }
        await confirmRulesMode(mode, RULES_MODE_TIMEOUT_MS);
        state.pendingRulesMode = "";
        state.pendingRulesPreviousMode = "";
        await refreshAll(false, false, true);
        await refreshRules(false, true);
        flash(`Routing mode applied locally with hard cutover: ${mode}.`, "good");
      } catch (err) {
        const rollbackMode = state.pendingRulesPreviousMode || (mode === "selective" ? "full" : "selective");
        state.pendingRulesMode = "";
        state.pendingRulesPreviousMode = "";
        // Repaint the router's REAL state rather than guessing.
        await refreshRulesMode();
        if (!state.rulesModeQuick && input) {
          input.checked = rollbackMode === "selective";
        }
        renderRulesModeUi(state.rules);
        flash(`Routing mode change failed: ${err.message}`, "bad");
        document.getElementById("rulesTraceOutput").textContent = `Routing mode change failed: ${err.message}`;
      } finally {
        setBusy(input, false);
        endForegroundTask();
      }
    }

    function renderAll(forceForm = false) {
      const runtime = state.runtime;
      const profile = activeProfile();
      if (runtime) {
        renderRuntime(runtime);
      }
      if (profile) {
        renderHeroAndSummary(profile);
        populateProfileSelect();
        populateProfileForm(profile, forceForm);
        renderManagedKey(profile);
        renderCheckSummary(profile);
        renderRemoteInfo(profile);
        renderCompareTables(profile);
        renderSyncOverview(profile);
      } else {
        renderHeroAndSummary(null);
      }
      updateAuthUi();
    }

    async function refreshAll(showMessage = false, forceForm = false, allowWhileBusy = false) {
      if ((state.foregroundBusy && !allowWhileBusy) || state.refreshBusy) {
        return;
      }
      state.refreshBusy = true;
      try {
        const [runtime, vps] = await Promise.all([
          callApi(runtimeApi, "status", null, { timeoutMs: 6000 }),
          callApi(vpsApi, "status", null, { timeoutMs: 6000 })
        ]);
        state.runtime = runtime;
        state.vps = vps;
        renderAll(forceForm);
        if (showMessage) {
          flash("Status refreshed.", "good");
        }
      } finally {
        state.refreshBusy = false;
      }
    }

    async function loadLogs() {
      if (state.foregroundBusy || state.logsBusy) {
        return;
      }
      state.logsBusy = true;
      try {
        const data = await callApi(runtimeApi, "logs", null, { timeoutMs: 8000 });
        const out = [
          "=== gl-switch ===",
          data.switch_logs || "(empty)",
          "",
          "=== xray access ===",
          data.access_logs || "(empty)",
          "",
          "=== xray error ===",
          data.error_logs || "(empty)"
        ].join("\n");
        document.getElementById("logsOutput").textContent = out;
      } catch (err) {
        document.getElementById("logsOutput").textContent = `Failed to load logs: ${err.message}`;
      } finally {
        state.logsBusy = false;
      }
    }

    /* ---- System Health ---- */
    function drawSparkline(canvasId, points, opts = {}) {
      const canvas = document.getElementById(canvasId);
      if (!canvas || !points.length) return;
      const ctx = canvas.getContext("2d");
      const dpr = window.devicePixelRatio || 1;
      const w = canvas.clientWidth;
      const h = canvas.clientHeight;
      canvas.width = w * dpr;
      canvas.height = h * dpr;
      ctx.scale(dpr, dpr);

      const color = opts.color || "var(--accent)";
      const fill = opts.fill || "rgba(11,95,255,0.08)";
      const yMin = opts.yMin != null ? opts.yMin : Math.min(...points);
      const yMax = opts.yMax != null ? opts.yMax : Math.max(...points);
      const range = yMax - yMin || 1;
      const pad = 2;

      ctx.clearRect(0, 0, w, h);

      // grid lines
      ctx.strokeStyle = "#e4e9ed";
      ctx.lineWidth = 0.5;
      for (let i = 0; i <= 4; i++) {
        const gy = pad + (h - 2 * pad) * (i / 4);
        ctx.beginPath(); ctx.moveTo(0, gy); ctx.lineTo(w, gy); ctx.stroke();
      }

      // y-axis labels
      ctx.fillStyle = "#8899aa";
      ctx.font = "10px system-ui, sans-serif";
      ctx.textAlign = "left";
      const fmt = opts.fmt || (v => v.toFixed(0));
      ctx.fillText(fmt(yMax), 2, pad + 10);
      ctx.fillText(fmt(yMin), 2, h - pad);

      // line
      ctx.beginPath();
      const step = w / Math.max(points.length - 1, 1);
      points.forEach((v, i) => {
        const x = i * step;
        const y = pad + (h - 2 * pad) * (1 - (v - yMin) / range);
        i === 0 ? ctx.moveTo(x, y) : ctx.lineTo(x, y);
      });
      ctx.strokeStyle = color;
      ctx.lineWidth = 1.5;
      ctx.stroke();

      // fill
      const last = points.length - 1;
      ctx.lineTo(last * step, h);
      ctx.lineTo(0, h);
      ctx.closePath();
      ctx.fillStyle = fill;
      ctx.fill();

      // bad-zone highlight for connectivity (0 = fail)
      if (opts.markZeros) {
        ctx.fillStyle = "rgba(193,56,56,0.18)";
        points.forEach((v, i) => {
          if (v === 0) {
            ctx.fillRect(i * step - step / 2, 0, step, h);
          }
        });
      }
    }

    async function loadHealth() {
      const btn = document.getElementById("healthBtn");
      btn.disabled = true;
      btn.textContent = "Loading...";
      try {
        // 20s, not 6s: when the router is degraded (e.g. a broken client
        // config makes xray retry-storm the VPS and peg the CPU) the health
        // CGI — which only reads local files — can still be slow to be
        // scheduled. A short timeout fails exactly when you most need the
        // data. On timeout we say why, rather than a bare "Failed".
        const data = await callApi(runtimeApi, "health", null, { timeoutMs: 20000 });
        const samples = data.samples || [];
        const alerts = data.alerts || [];
        const memTotalMb = (data.mem_total_kb || 491388) / 1024;

        if (!samples.length) {
          document.getElementById("healthEmpty").textContent = "Health monitor has no data yet. It collects a sample every 30 s.";
          return;
        }

        document.getElementById("healthEmpty").style.display = "none";
        document.getElementById("healthCharts").style.display = "block";

        const memPts = samples.map(s => s.ma / 1024);
        const rssPts = samples.map(s => s.xr / 1024);
        const ctPts  = samples.map(s => s.ct);
        const coPts  = samples.map(s => s.co);

        drawSparkline("chartMem", memPts, {
          yMin: 0, yMax: memTotalMb,
          color: "#0d8b4b", fill: "rgba(13,139,75,0.08)",
          fmt: v => v.toFixed(0) + " MB"
        });
        drawSparkline("chartRss", rssPts, {
          yMin: 0, yMax: Math.max(60, ...rssPts),
          color: "#0b5fff", fill: "rgba(11,95,255,0.08)",
          fmt: v => v.toFixed(0) + " MB"
        });
        drawSparkline("chartCt", ctPts, {
          yMin: 0,
          color: "#b36c00", fill: "rgba(179,108,0,0.08)",
          fmt: v => v.toFixed(0)
        });
        drawSparkline("chartConn", coPts, {
          yMin: 0, yMax: 1,
          color: "#0d8b4b", fill: "rgba(13,139,75,0.08)",
          markZeros: true,
          fmt: v => v === 1 ? "OK" : "FAIL"
        });

        // time range
        const first = samples[0];
        const last = samples[samples.length - 1];
        const dur = last.t - first.t;
        const durMin = (dur / 60).toFixed(0);
        const meta = document.getElementById("healthMeta");
        meta.textContent = `${samples.length} samples over ${durMin} min \u2014 ` +
          `mem ${memPts[memPts.length-1].toFixed(0)}/${memTotalMb.toFixed(0)} MB, ` +
          `xray RSS ${rssPts[rssPts.length-1].toFixed(1)} MB, ` +
          `conntrack ${ctPts[ctPts.length-1]}`;

        // alerts (filter out guard actions — they get their own section)
        const guardAlerts = alerts.filter(a => /^GUARD_/.test(a.msg));
        const otherAlerts = alerts.filter(a => !/^GUARD_/.test(a.msg));
        const alertDiv = document.getElementById("healthAlerts");
        if (otherAlerts.length) {
          alertDiv.innerHTML = '<div class="label" style="color:var(--bad);margin-bottom:4px;">Alerts</div>' +
            otherAlerts.slice(-20).map(a => {
              const d = new Date(a.t * 1000);
              const ts = d.toLocaleTimeString();
              return `<div style="font-size:12px;color:var(--bad);font-family:monospace;">${ts} ${a.msg}</div>`;
            }).join("");
        } else {
          alertDiv.innerHTML = '<div class="label" style="color:var(--good);">No alerts</div>';
        }

        // crash history (persists across reboots on flash)
        const crashes = data.crashes || [];
        const crashDiv = document.getElementById("healthCrashes");
        if (crashes.length) {
          crashDiv.innerHTML = '<div class="label" style="color:#c00;margin-bottom:4px;">Crash History (survived reboots)</div>' +
            crashes.slice(-10).map(c => {
              const d = new Date(c.t * 1000);
              const ts = d.toLocaleDateString() + " " + d.toLocaleTimeString();
              return `<div style="font-size:12px;color:#c00;font-family:monospace;">${ts} ${c.msg}</div>`;
            }).join("");
        } else {
          crashDiv.innerHTML = "";
        }

        // guard actions (proactive restarts/flushes)
        const guardDiv = document.getElementById("healthGuards");
        if (guardAlerts.length) {
          guardDiv.innerHTML = '<div class="label" style="color:#b36c00;margin-bottom:4px;">Guard Actions</div>' +
            guardAlerts.slice(-10).map(a => {
              const d = new Date(a.t * 1000);
              const ts = d.toLocaleTimeString();
              return `<div style="font-size:12px;color:#b36c00;font-family:monospace;">${ts} ${a.msg}</div>`;
            }).join("");
        } else {
          guardDiv.innerHTML = "";
        }
      } catch (err) {
        const isTimeout = /timeout|abort/i.test(err.message || "");
        document.getElementById("healthEmpty").style.display = "";
        document.getElementById("healthEmpty").textContent = isTimeout
          ? "Health timed out. The router is likely under heavy load — a broken client config makes xray retry-storm the VPS. Run Diagnose & Repair, or revive the router config, then retry."
          : `Failed: ${err.message}`;
      } finally {
        btn.disabled = false;
        btn.textContent = "Load Health";
      }
    }

