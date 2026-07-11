    async function selectProfile(profileId) {
      beginForegroundTask(`Switching to profile "${profileId}"...`, 10000);
      try {
        const data = await callApi(vpsApi, "select_profile", { profile_id: profileId }, { timeoutMs: 10000 });
        if (data.ok === false) {
          throw new Error(data.error || "backend error");
        }
        if (data.status) {
          state.vps = data.status;
        }
        clearDirty();
        renderAll(true);
        flash(`Active profile switched to "${profileId}".`, "good");
      } catch (err) {
        flash(`Failed to switch profile: ${err.message}`, "bad");
      } finally {
        endForegroundTask();
      }
    }

    async function createProfile(button) {
      beginForegroundTask("Creating new VPS profile...", 15000);
      setBusy(button, true);
      try {
        const data = await callApi(vpsApi, "create_profile", {}, { timeoutMs: 15000 });
        if (data.ok === false) {
          throw new Error(data.error || "backend error");
        }
        if (data.status) {
          state.vps = data.status;
        }
        clearDirty();
        renderAll(true);
        flash(`Created new VPS profile "${data.created_profile_id || "new"}".`, "good");
      } catch (err) {
        flash(`Failed to create profile: ${err.message}`, "bad");
      } finally {
        setBusy(button, false);
        endForegroundTask();
      }
    }

    // checkProfile/applyProfile were replaced by diagnose_repair — the
    // read-only inspection is done by refresh_remote_cache inside the
    // pipeline, and the full apply/sync is the pipeline itself.

    // Render the JSON step report from the diagnose_repair backend action
    // into the #repairSteps list. Icons: ok=OK, fixed=FIX, failed=FAIL.
    // Any "overall" pseudo-step becomes the summary line rather than a
    // list row so the user sees the verdict without hunting. rawLog, if
    // present, is placed inside a collapsed <details> block so the
    // operator can inspect the underlying SSH stderr / pipeline output
    // without visual noise on a clean success.
    function renderRepairReport(steps, rawLog) {
      const reportEl = document.getElementById("repairReport");
      const listEl = document.getElementById("repairSteps");
      const summaryEl = document.getElementById("repairSummary");
      const rawWrap = document.getElementById("repairRawWrap");
      const rawPre = document.getElementById("repairRawLog");
      const hasSteps = steps && steps.length;
      const hasRaw = rawLog && rawLog.length;
      if (!hasSteps && !hasRaw) {
        reportEl.style.display = "none";
        listEl.innerHTML = "";
        summaryEl.textContent = "";
        rawWrap.style.display = "none";
        rawPre.textContent = "";
        return;
      }
      reportEl.style.display = "";
      const iconFor = (status) => {
        if (status === "ok") return { txt: "OK", color: "#57c877" };
        if (status === "fixed") return { txt: "FIX", color: "#e6d34a" };
        if (status === "skipped") return { txt: "SKIP", color: "#8b98a5" };
        return { txt: "FAIL", color: "#e57373" };
      };
      const rows = [];
      let overall = null;
      (steps || []).forEach((step) => {
        if (step.id === "overall") {
          overall = step;
          return;
        }
        const icon = iconFor(step.status);
        rows.push(`<li style="padding:2px 0;"><span style="display:inline-block;min-width:44px;color:${icon.color};font-weight:600;">${icon.txt}</span> <span style="min-width:110px;display:inline-block;">${escapeHtml(step.id || "")}</span> <span style="color:#c5cfd8;">${escapeHtml(step.message || "")}</span>${step.details ? `<div style="margin-left:56px;color:#8b98a5;font-size:12px;white-space:pre-wrap;">${escapeHtml(step.details)}</div>` : ""}</li>`);
      });
      listEl.innerHTML = rows.join("");
      if (overall) {
        const icon = iconFor(overall.status);
        summaryEl.innerHTML = `<span style="color:${icon.color};font-weight:600;">${icon.txt}</span> ${escapeHtml(overall.message || "")}`;
      } else if (hasSteps) {
        const failed = steps.filter((s) => s.status === "failed").length;
        const fixed = steps.filter((s) => s.status === "fixed").length;
        summaryEl.textContent = failed
          ? `${failed} step(s) failed, ${fixed} fixed.`
          : fixed
          ? `All checks pass; ${fixed} step(s) were auto-repaired.`
          : "All checks pass; nothing needed fixing.";
      } else {
        summaryEl.textContent = "";
      }
      if (hasRaw) {
        rawWrap.style.display = "";
        rawPre.textContent = rawLog;
      } else {
        rawWrap.style.display = "none";
        rawPre.textContent = "";
      }
    }

    // Drives the animated progress panel while a repair request is in
    // flight. The backend runs the whole pipeline as one request and
    // returns the per-step report at the end, so we can't stream real
    // sub-steps; instead we advance a phase label on a timer to show the
    // user that work is happening and roughly where it is. Cleared when
    // the request resolves.
    let repairProgressTimer = null;
    function startRepairProgress() {
      const panel = document.getElementById("repairProgress");
      const textEl = document.getElementById("repairProgressText");
      const elapsedEl = document.getElementById("repairProgressElapsed");
      panel.style.display = "";
      const phases = [
        [0, "Establishing SSH to the VPS…"],
        [3, "Uploading config, meta and repair script…"],
        [6, "Running repair pipeline (binary, perms, certs, config, runtime)…"],
        [20, "Still working — waiting on the VPS to converge…"],
        [45, "Taking longer than usual — the VPS may be slow to restart…"],
      ];
      const started = Date.now();
      const tick = () => {
        const secs = Math.floor((Date.now() - started) / 1000);
        let label = phases[0][1];
        for (const [at, txt] of phases) {
          if (secs >= at) label = txt;
        }
        textEl.textContent = label;
        elapsedEl.textContent = `${secs}s`;
      };
      tick();
      repairProgressTimer = setInterval(tick, 1000);
    }
    function stopRepairProgress() {
      if (repairProgressTimer) {
        clearInterval(repairProgressTimer);
        repairProgressTimer = null;
      }
      document.getElementById("repairProgress").style.display = "none";
    }

    // Called for each attempt at diagnose_repair. Handles the three
    // response shapes: ok=true (report), ok=false + credentials_required
    // (open the inline form), or ok=false + steps (report + flash).
    // Guarded by state.repairRunning so a second click (or the Retry
    // button firing while the first request is still in flight) cannot
    // launch a concurrent pipeline — that used to spawn two backend runs,
    // the second returning a confusing error.
    async function runDiagnoseRepairOnce(button, extraPayload) {
      if (state.repairRunning) {
        flash("A repair run is already in progress — please wait for it to finish.", "warn");
        return;
      }
      state.repairRunning = true;
      const payload = formPayload();
      if (extraPayload) {
        Object.assign(payload, extraPayload);
      }
      // Disable both entry points for the whole duration, not just the
      // button that was clicked.
      const repairBtn = document.getElementById("diagnoseRepairBtn");
      const credsBtn = document.getElementById("repairCredsSubmit");
      setBusy(repairBtn, true);
      setBusy(credsBtn, true);
      startRepairProgress();
      beginForegroundTask("Running diagnose & repair pipeline on the VPS...", 60000);
      try {
        const data = await callApi(vpsApi, "diagnose_repair", payload, { timeoutMs: 90000 });
        if (data.error === "busy") {
          flash("A repair run is already in progress on the router — please wait.", "warn");
          return;
        }
        if (data.error === "credentials_required") {
          document.getElementById("repairCredsForm").style.display = "";
          const reasonEl = document.getElementById("repairCredsReason");
          if (data.reason) reasonEl.textContent = data.reason;
          renderRepairReport(data.steps || [], data.raw_log || "");
          // Distinguish "need password" from "VPS unreachable" so the
          // operator does not type a password into a form that cannot
          // help. The raw log carries the exact OpenSSH line.
          const raw = (data.raw_log || "").toLowerCase();
          if (raw.includes("connection refused") || raw.includes("timed out") || raw.includes("no route")) {
            flash("VPS is not reachable over SSH right now (see raw log). A password will not help until the VPS is back.", "warn");
          } else if (extraPayload && extraPayload.ssh_password) {
            flash("That password did not establish SSH. Check it and the raw log below.", "bad");
          } else {
            flash("Router's SSH key was rejected — enter the VPS root password once to re-establish access.", "warn");
          }
          return;
        }
        if (data.status) state.vps = data.status;
        renderRepairReport(data.steps || [], data.raw_log || "");
        if (data.ok) {
          document.getElementById("repairCredsForm").style.display = "none";
          document.getElementById("repairSshPassword").value = "";
          await refreshAll(false, true, true);
          if (data.router_apply === "drift_detected") {
            flash("VPS repaired. The router client config differs from the profile — review it before applying; the repair does NOT change the router config automatically.", "warn");
          } else {
            flash("Diagnose & repair completed successfully.", "good");
          }
        } else {
          // Show the step tree AND auto-expand the raw log so the operator
          // sees exactly which node failed and why, instead of a bare
          // "one or more steps failed". Name the failed steps in the flash.
          const failed = (data.steps || []).filter((s) => s.status === "failed");
          const failedNames = failed.map((s) => s.id).join(", ");
          const rawWrap = document.getElementById("repairRawWrap");
          if (rawWrap && (data.raw_log || "").length) {
            rawWrap.open = true;
          }
          let reason;
          if (data.error === "pipeline_setup_failed") {
            reason = `could not start the repair pipeline: ${data.reason || "unknown"}`;
          } else if (failedNames) {
            reason = `failed step(s): ${failedNames}. See the report and raw log below.`;
          } else {
            reason = data.reason || data.error || "one or more steps failed — see the report and raw log below.";
          }
          flash(`Repair finished with issues — ${reason}`, "bad");
        }
      } catch (err) {
        flash(`Repair failed: ${err.message}`, "bad");
      } finally {
        state.repairRunning = false;
        stopRepairProgress();
        setBusy(document.getElementById("diagnoseRepairBtn"), false);
        setBusy(document.getElementById("repairCredsSubmit"), false);
        endForegroundTask();
      }
    }

    async function diagnoseRepair(button) {
      // First attempt: no extra credentials. If the backend needs SSH
      // credentials it will surface credentials_required and open the
      // inline password form. The user then clicks Retry, which calls
      // runDiagnoseRepairOnce again with the entered password.
      document.getElementById("repairCredsForm").style.display = "none";
      await runDiagnoseRepairOnce(button, null);
    }

    document.getElementById("createProfileBtn").addEventListener("click", (event) => createProfile(event.currentTarget));

    // Rules tab navigation. One button-row toggles which .rules-tab-panel
    // is visible. Active tab is highlighted with the accent color and a
    // border-bottom underline; inactive tabs stay muted. Simple enough
    // that a full CSS class approach would be more indirection than it
    // saves, so we mutate the inline styles the buttons ship with.
    function activateRulesTab(tabId) {
      const panels = { local: "rulesTabLocal", git: "rulesTabGit", external: "rulesTabExternal", status: "rulesTabStatus" };
      Object.entries(panels).forEach(([key, elId]) => {
        const el = document.getElementById(elId);
        if (el) el.style.display = key === tabId ? "" : "none";
      });
      document.querySelectorAll(".rules-tab-btn").forEach((btn) => {
        const active = btn.dataset.tab === tabId;
        btn.style.color = active ? "#e6d34a" : "#8b98a5";
        btn.style.borderBottomColor = active ? "#e6d34a" : "transparent";
      });
    }
    document.querySelectorAll(".rules-tab-btn").forEach((btn) => {
      btn.addEventListener("click", () => activateRulesTab(btn.dataset.tab));
    });
    document.getElementById("diagnoseRepairBtn").addEventListener("click", (event) => diagnoseRepair(event.currentTarget));
    document.getElementById("repairCredsCancel").addEventListener("click", () => {
      document.getElementById("repairCredsForm").style.display = "none";
      document.getElementById("repairSshPassword").value = "";
    });
    document.getElementById("repairCredsSubmit").addEventListener("click", () => {
      const pwd = document.getElementById("repairSshPassword").value;
      const btn = document.getElementById("diagnoseRepairBtn");
      if (!pwd) {
        flash("Enter the VPS root password to retry.", "bad");
        return;
      }
      runDiagnoseRepairOnce(btn, { ssh_password: pwd });
    });
    document.getElementById("logsBtn").addEventListener("click", loadLogs);
    document.getElementById("healthBtn").addEventListener("click", loadHealth);
    document.getElementById("smokeBtn").addEventListener("click", runSmoke);
    document.getElementById("recoverPathBtn").addEventListener("click", (event) => recoverPath(event.currentTarget));
    document.getElementById("rulesSaveConfigBtn").addEventListener("click", (event) => saveRulesConfig(event.currentTarget));
    document.getElementById("rulesApplyBtn").addEventListener("click", (event) => saveSyncList(event.currentTarget));
    document.getElementById("rulesPullBtn").addEventListener("click", (event) => pullRules(event.currentTarget));
    document.getElementById("rulesPushBtn").addEventListener("click", (event) => pushRules(event.currentTarget));
    document.getElementById("rulesLoadTextBtn").addEventListener("click", (event) => loadRulesText(event.currentTarget));
    document.getElementById("rulesExternalRunBtn").addEventListener("click", (event) => runExternalSource(event.currentTarget));
    document.getElementById("rulesSummaryChips").addEventListener("click", (event) => {
      const errorChip = event.target.closest(".rules-external-error-chip");
      if (errorChip) {
        const el = document.getElementById("rulesExternalSources");
        if (el) el.scrollIntoView({ behavior: "smooth", block: "center" });
        flash(errorChip.title || "External source error", "bad");
      }
    });
    document.getElementById("rulesExternalSources").addEventListener("click", (event) => {
      const downloadFresh = event.target.closest(".rules-external-download-fresh-btn");
      if (downloadFresh) {
        downloadExternalFresh(downloadFresh, downloadFresh.dataset.sourceId || "");
        return;
      }
      const downloadStored = event.target.closest(".rules-external-download-stored-btn");
      if (downloadStored) {
        downloadExternalStored(downloadStored, downloadStored.dataset.sourceId || "");
        return;
      }
      const editBtn = event.target.closest(".rules-external-edit-btn");
      if (editBtn) {
        openScriptEditor(editBtn.dataset.sourceId || "");
        return;
      }
    });
    document.getElementById("rulesExternalSources").addEventListener("change", (event) => {
      if (event.target.matches(".rules-external-enable-input")) {
        markRulesConfigDirty();
        updateRulesConfigUi();
      }
    });
    document.getElementById("rulesAddExternalSourceBtn").addEventListener("click", () => openScriptEditor(""));
    document.getElementById("scriptEditorClose").addEventListener("click", closeScriptEditor);
    document.getElementById("scriptEditorModal").addEventListener("click", (event) => {
      if (event.target.id === "scriptEditorModal") closeScriptEditor();
    });
    document.getElementById("scriptEditorSaveBtn").addEventListener("click", saveExternalScript);
    document.getElementById("scriptEditorDeleteBtn").addEventListener("click", (event) => {
      const sourceId = event.currentTarget.dataset.sourceId || "";
      if (sourceId) deleteExternalScript(sourceId);
    });
    document.getElementById("scriptEditorRevertBtn").addEventListener("click", revertScriptEditor);
    ["scriptEditorLabel", "scriptEditorUrl", "scriptEditorMaxTargets", "scriptEditorCode"].forEach((id) => {
      document.getElementById(id).addEventListener("input", updateScriptEditorDirtyState);
    });
    document.getElementById("rulesTextModalClose").addEventListener("click", hideRulesTextModal);
    document.getElementById("rulesTextModal").addEventListener("click", (event) => {
      if (event.target.id === "rulesTextModal") {
        hideRulesTextModal();
      }
    });
    document.getElementById("rulesModeToggle").addEventListener("change", (event) => {
      setRulesMode(event.currentTarget.checked ? "selective" : "full", event.currentTarget);
    });
    document.getElementById("profileSelect").addEventListener("change", (event) => {
      selectProfile(event.target.value);
    });
    document.getElementById("authMode").addEventListener("change", () => {
      markDirty();
      updateAuthUi();
    });
    document.getElementById("vpsProfile").addEventListener("change", markDirty);

    [
      "profileId",
      "profileLabel",
      "vpsHost",
      "sshPort",
      "sshUser",
      "sshPassword",
      "bootstrapKey"
    ].forEach((id) => {
      const el = document.getElementById(id);
      if (el) {
        el.addEventListener("input", markDirty);
      }
    });
    document.getElementById("rulesText").addEventListener("input", markRulesDirty);
    [
      "rulesRepoFetchUrl",
      "rulesRepoPushUrl",
      "rulesRepoBranch",
      "rulesSyncInterval",
      "rulesExternalInterval",
      "rulesGitHttpUsername",
      "rulesGitHttpPassword",
      "rulesGitSshPrivateKey"
    ].forEach((id) => {
      const el = document.getElementById(id);
      if (el) {
        el.addEventListener("input", markRulesConfigDirty);
      }
    });
    [
      "rulesGitSyncEnabled",
      "rulesEnablePush",
      "rulesGitAuthMode"
    ].forEach((id) => {
      const el = document.getElementById(id);
      if (el) {
        el.addEventListener("change", markRulesConfigDirty);
      }
    });
    document.getElementById("rulesGitSyncEnabled").addEventListener("change", updateRulesConfigUi);
    document.getElementById("rulesEnablePush").addEventListener("change", updateRulesConfigUi);
    document.getElementById("rulesGitAuthMode").addEventListener("change", updateRulesConfigUi);
    [
      "rulesRepoFetchUrl",
      "rulesGitHttpUsername",
      "rulesGitHttpPassword"
    ].forEach((id) => {
      const el = document.getElementById(id);
      if (el) {
        el.addEventListener("input", updateRulesConfigUi);
      }
    });

    setStartupControlsDisabled(true);
    flashLoading("Loading current router and VPS state...");

    callApi(runtimeApi, "status", null, { timeoutMs: 8000 })
      .then((runtime) => {
        state.runtime = runtime;
        renderAll(false);
      })
      .catch(() => {});

    callApi(vpsApi, "status", null, { timeoutMs: 8000 })
      .then((vps) => {
        state.vps = vps;
        renderAll(true);
        state.uiReady = true;
        setStartupControlsDisabled(false);
        clearFlash();
      })
      .catch((err) => {
        state.uiReady = true;
        setStartupControlsDisabled(false);
        flash(`Initial load failed: ${err.message}`, "bad");
      });

    refreshRules(false).catch(() => {});

    setInterval(() => {
      refreshAll(false, false).catch(() => {});
      refreshRules(false).catch(() => {});
    }, 15000);

