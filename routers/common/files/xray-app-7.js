    // Install banner — polls /cgi-bin/xray-admin?action=install_status which
    // returns the contents of /tmp/vpn-xray-install-status.json (written by
    // common/lib/install-progress.sh during a deploy). Poll runs forever; a
    // missing or empty status file resolves to state=idle and hides the
    // banner. Failed state stays visible until the operator re-runs the
    // install successfully.
    // Remembers the state seen on the previous poll so a "complete" banner is
    // surfaced only on the running->complete transition the operator actually
    // watched — never re-shown on every 5s poll of a status file that stays
    // "complete" until the next install (that made the banner blink forever).
    let installBannerPrevState = "idle";
    async function refreshInstallBanner() {
      const banner = document.getElementById("installBanner");
      if (!banner) return;
      let data;
      try {
        const resp = await fetch(`${runtimeApi}?action=install_status`, { cache: "no-store" });
        data = await resp.json();
      } catch (_err) {
        // Network blip or CGI not reachable. Keep whatever is currently
        // shown — the banner is meant to survive transient failures and
        // page reloads.
        return;
      }
      const installState = (data && data.state) || "idle";
      const installPrevState = installBannerPrevState;
      installBannerPrevState = installState;
      if (installState === "idle") {
        // Even with no active install, surface selective fallback at the
        // top of the page so the operator notices the temporary FULL
        // state immediately. The page-level `state` global is shadowed
        // here on purpose — read rules from window-level lookups.
        const rulesData = (window.state && window.state.rules) || null;
        const fallbackActive = !!(rulesData && rulesData.selective_fallback_active);
        const fallbackReason = (rulesData && rulesData.selective_fallback_reason) || "rules sync failed";
        if (fallbackActive) {
          banner.hidden = false;
          banner.classList.remove("running", "complete");
          document.getElementById("installBannerTitle").textContent = "Selective routing pending";
          document.getElementById("installBannerBody").textContent = "Currently in FULL mode because the rules repository is unreachable. The router retries every sync interval and switches back to selective automatically.";
          const fixEl = document.getElementById("installBannerFix");
          fixEl.textContent = `Cause: ${fallbackReason}`;
          fixEl.hidden = false;
          return;
        }
        banner.hidden = true;
        return;
      }
      banner.hidden = false;
      banner.classList.remove("running", "complete");
      const titleEl = document.getElementById("installBannerTitle");
      const bodyEl = document.getElementById("installBannerBody");
      const fixEl = document.getElementById("installBannerFix");
      const stepIndex = data.step_index || 0;
      const stepTotal = data.step_total || 0;
      const stepName = data.step_name || "";
      if (installState === "running") {
        banner.classList.add("running");
        titleEl.textContent = "Install in progress";
        bodyEl.textContent = stepTotal > 0
          ? `Step ${stepIndex}/${stepTotal}: ${stepName}`
          : "Working...";
        fixEl.hidden = true;
      } else if (installState === "failed") {
        titleEl.textContent = `Install failed at step ${stepIndex}/${stepTotal}: ${stepName}`;
        bodyEl.textContent = data.error_cause || "An install step did not complete successfully.";
        if (data.error_fix) {
          fixEl.textContent = `Fix: ${data.error_fix}`;
          fixEl.hidden = false;
        } else {
          fixEl.hidden = true;
        }
      } else if (installState === "complete") {
        if (installPrevState === "running") {
          // Fresh completion the operator just watched finish — show once,
          // then auto-hide after 8s. Subsequent polls of the same "complete"
          // state fall through and do nothing (no re-show => no blink).
          banner.classList.add("complete");
          titleEl.textContent = "Install complete";
          bodyEl.textContent = `${stepTotal}/${stepTotal} steps OK`;
          fixEl.hidden = true;
          setTimeout(() => {
            if (!banner.classList.contains("running")) {
              banner.hidden = true;
            }
          }, 8000);
        } else {
          // Stale/persistent "complete" (page load, or already dismissed).
          // The status file stays "complete" until the next install, so this
          // is not news — keep the banner hidden instead of blinking it.
          banner.hidden = true;
        }
      }
    }
    refreshInstallBanner();
    setInterval(refreshInstallBanner, 5000);

    // Profiles persist SSH access only. Xray values shown in the advanced
    // pane are read-only derivatives of the live VPS.
    const serverPortField = document.getElementById("serverPort");
    if (serverPortField) serverPortField.readOnly = true;

    async function saveVpsAccess(button) {
      beginForegroundTask("Saving VPS access on the router...", 10000);
      setBusy(button, true);
      try {
        const data = await callApi(vpsApi, "save_profile", formPayload(), { timeoutMs: 10000 });
        if (data.ok === false) throw new Error(data.error || "backend error");
        if (data.status) state.vps = data.status;
        clearDirty();
        populateProfileSelect();
        document.getElementById("profileActionHint").textContent = "Access saved. Next: click Check & Configure VPS.";
        flash("VPS access saved on the router. The VPS has not been changed yet.", "good");
      } catch (err) {
        flash(`Failed to save VPS access: ${err.message}`, "bad");
      } finally {
        setBusy(button, false);
        endForegroundTask();
        renderAll(false);
      }
    }

    async function waitForRouterApply() {
      const deadline = Date.now() + 120000;
      while (Date.now() < deadline) {
        await sleep(1000);
        const data = await callApi(vpsApi, "apply_router_status", null, { timeoutMs: 10000 });
        const job = data.job || {};
        if (job.state === "scheduled" || job.state === "running") continue;
        return job;
      }
      throw new Error("Router profile apply did not finish within 120 seconds.");
    }

    function renderApplyProfileButton(inspectStatus, remoteDiff, routerDiff) {
      const button = document.getElementById("applyRouterProfileBtn");
      if (!button) return;
      const canApply = inspectStatus === "ok" && remoteDiff.length === 0 && routerDiff.length > 0;
      button.disabled = state.foregroundBusy || !canApply;
      button.title = canApply
        ? "Apply this VPS-derived profile to the live router path. The router rolls back automatically if verification fails."
        : (routerDiff.length === 0 ? "This profile is already active on the router." : "Run Check & Configure VPS successfully before applying.");
    }

    async function applyRouterProfile(button) {
      const profile = activeProfile();
      if (!profile) return flash("No VPS profile is selected.", "bad");
      if (state.formDirty) return flash("Save VPS Access before applying the profile.", "warn");
      if (!window.confirm(`Apply profile "${profile.label || profile.id}" to the live router path? Existing traffic will reconnect.`)) return;
      beginForegroundTask("Applying the verified VPS profile to the router...", 120000);
      setBusy(button, true);
      document.getElementById("profileActionHint").textContent = "Applying profile and verifying egress through the new VPS…";
      try {
        const start = await callApi(vpsApi, "apply_router", null, { timeoutMs: 10000 });
        if (start.ok === false) throw new Error(start.error || "backend error");
        const job = await waitForRouterApply();
        if (job.state !== "done") throw new Error(job.message || "router apply failed");
        await refreshAll(false, true, true);
        document.getElementById("profileActionHint").textContent = "Profile applied. Target now matches the selected VPS.";
        flash(job.message || "Profile applied and verified through the new VPS.", "good");
      } catch (err) {
        await refreshAll(false, true, true).catch(() => {});
        document.getElementById("profileActionHint").textContent = "Apply failed; the previous working router path was restored.";
        flash(`Failed to apply profile: ${err.message}`, "bad");
      } finally {
        setBusy(button, false);
        endForegroundTask();
        renderAll(false);
      }
    }

    const saveProfileButton = document.getElementById("saveProfileBtn");
    if (saveProfileButton) {
      saveProfileButton.addEventListener("click", () => saveVpsAccess(saveProfileButton));
    }
    const applyRouterProfileButton = document.getElementById("applyRouterProfileBtn");
    if (applyRouterProfileButton) {
      applyRouterProfileButton.addEventListener("click", () => applyRouterProfile(applyRouterProfileButton));
    }
