    function shouldAutoloadRulesText(data) {
      const sourceCount = Number(data?.source_count || 0) || 0;
      return sourceCount > 0 && sourceCount <= RULES_TEXT_AUTOLOAD_SOURCE_LIMIT;
    }

    async function refreshRules(includeRulesText = false, allowForegroundBusy = false) {
      if ((state.foregroundBusy && !allowForegroundBusy) || state.rulesBusy) {
        return;
      }
      state.rulesBusy = true;
      try {
        const data = await callApi(
          rulesApi,
          "status",
          { include_rules_text: includeRulesText ? "1" : "0" },
          { timeoutMs: includeRulesText ? RULES_TEXT_TIMEOUT_MS : RULES_STATUS_TIMEOUT_MS }
        );
        state.rules = data;
        renderRules(data);
        if (
          !includeRulesText &&
          !state.rulesTextLoaded &&
          !state.rulesDirty &&
          shouldAutoloadRulesText(data)
        ) {
          const fullData = await callApi(
            rulesApi,
            "status",
            { include_rules_text: "1" },
            { timeoutMs: RULES_TEXT_TIMEOUT_MS }
          );
          state.rules = fullData;
          renderRules(fullData);
        }
      } finally {
        state.rulesBusy = false;
      }
    }

    async function loadRulesText(button) {
      beginForegroundTask("Loading the full shared rules list from the router...", RULES_TEXT_TIMEOUT_MS, "rules");
      setBusy(button, true);
      try {
        await refreshRules(true, true);
        flash("Current shared rules list loaded.", "good");
      } catch (err) {
        flash(`Failed to load the shared rules list: ${err.message}`, "bad");
      } finally {
        setBusy(button, false);
        endForegroundTask();
      }
    }

    async function saveRulesConfig(button) {
      beginForegroundTask("Saving rules settings on the router...", RULES_SAVE_CONFIG_TIMEOUT_MS, "rules");
      setBusy(button, true);
      try {
        const data = await callApi(rulesApi, "save_config", rulesConfigPayload(), { timeoutMs: RULES_SAVE_CONFIG_TIMEOUT_MS });
        if (data.ok === false) {
          throw new Error(data.error || "backend error");
        }
        state.rules = data;
        clearRulesConfigDirty();
        renderRules(data);
        flash(data.git_sync_enabled ? "Rules settings saved." : "Git sync disabled. Router stays in local-only rules mode.", "good");
      } catch (err) {
        flash(`Failed to save rules settings: ${err.message}`, "bad");
        document.getElementById("rulesTraceOutput").textContent = `Failed to save rules settings: ${err.message}`;
      } finally {
        setBusy(button, false);
        endForegroundTask();
      }
    }

    function syncModeVerb(mode) {
      switch (mode) {
        case "pull":
          return "Pulling Git rules";
        case "push":
          return "Pushing Git rules";
        case "apply":
          return "Applying local rules";
        default:
          return "Syncing rules";
      }
    }

    async function runRulesSync(button, mode) {
      const verb = syncModeVerb(mode);
      beginForegroundTask(`${verb} on this router...`, RULES_SYNC_TIMEOUT_MS, "rules");
      setBusy(button, true);
      try {
        const payload = {
          base_repo_head: state.rulesEditorBaseHead || state.rules?.repo_head || "",
          sync_mode: mode
        };
        if (state.rulesDirty && state.rulesTextLoaded) {
          payload.rules_text = document.getElementById("rulesText").value;
        }
        const data = await callApi(rulesApi, "sync_rules", payload, { timeoutMs: RULES_STATUS_TIMEOUT_MS });
        if (data.ok === false) {
          throw new Error(data.error || "backend error");
        }
        state.rules = data;
        renderRules(data);
        const finalData = data.ui_job_state === "running"
          ? await waitForRulesJob(verb, RULES_SYNC_TIMEOUT_MS, data.ui_job_id || "")
          : data;
        state.rules = finalData;
        clearRulesDirty();
        renderRules(finalData);
        if (state.rulesTextLoaded) {
          await refreshRules(true, true);
        }
        await refreshAll(false, false, true);
        flash((state.rules?.sync_phase_message || state.rules?.last_sync_message || finalData.sync_phase_message || finalData.last_sync_message || `${verb} finished.`), "good");
        backgroundSmokeRefresh().catch(() => {});
      } catch (err) {
        flash(`${verb} failed: ${err.message}`, "bad");
        document.getElementById("rulesTraceOutput").textContent = formatRulesJobFailureDetails(err.routerJob || state.rules, `${verb} failed: ${err.message}`);
      } finally {
        setBusy(button, false);
        endForegroundTask();
      }
    }

    async function applyRules(button) {
      return runRulesSync(button, "apply");
    }

    async function pullRules(button) {
      return runRulesSync(button, "pull");
    }

    async function pushRules(button) {
      return runRulesSync(button, "push");
    }

    // The one "Save & Sync List" action next to the editor. It saves the local
    // list (runRulesSync sends the dirty editor text) and, when Git sync is on,
    // does the automatic two-way sync: pull remote, merge (union — both unique
    // sides kept, no manual conflict step), push when push is ready, then apply.
    // With Git off it just saves + applies locally. No separate Pull/Push.
    async function saveSyncList(button) {
      const rules = state.rules || {};
      const gitSyncEnabled = !!rules.git_sync_enabled && !!rules.git_configured;
      let mode = "apply"; // local save + apply
      if (gitSyncEnabled) {
        mode = rules.git_push_ready ? "push" : "pull"; // push = bidirectional, pull = fetch+merge+apply
      }
      return runRulesSync(button, mode);
    }

    function triggerDownload(text, filename) {
      const blob = new Blob([text], { type: "text/plain" });
      const url = URL.createObjectURL(blob);
      const a = document.createElement("a");
      a.href = url;
      a.download = filename;
      document.body.appendChild(a);
      a.click();
      document.body.removeChild(a);
      URL.revokeObjectURL(url);
    }

    async function downloadExternalFresh(button, sourceId) {
      const source = externalSourceById(sourceId);
      if (!source) { flash("Source metadata missing.", "bad"); return; }
      beginForegroundTask(`Generating fresh output for ${source.label || source.id}...`, RULES_EXTERNAL_PREVIEW_TIMEOUT_MS, "rules");
      setBusy(button, true);
      try {
        const resp = await fetch(rulesApi, {
          method: "POST",
          headers: { "Content-Type": "application/x-www-form-urlencoded" },
          body: `action=download_external_file&source_id=${encodeURIComponent(sourceId)}&type=preview`
        });
        const contentType = resp.headers.get("content-type") || "";
        if (contentType.includes("application/json")) {
          const data = await resp.json();
          throw new Error(data.error || "backend error");
        }
        const text = await resp.text();
        triggerDownload(text, `${sourceId}_fresh.txt`);
        flash(`Downloaded fresh output for ${source.label || source.id}.`, "good");
      } catch (err) {
        flash(`Fresh download failed: ${err.message}`, "bad");
      } finally {
        setBusy(button, false);
        endForegroundTask();
      }
    }

    async function downloadExternalStored(button, sourceId) {
      const source = externalSourceById(sourceId);
      if (!source) { flash("Source metadata missing.", "bad"); return; }
      beginForegroundTask(`Downloading stored file for ${source.label || source.id}...`, RULES_TEXT_TIMEOUT_MS, "rules");
      setBusy(button, true);
      try {
        const resp = await fetch(rulesApi, {
          method: "POST",
          headers: { "Content-Type": "application/x-www-form-urlencoded" },
          body: `action=download_external_file&source_id=${encodeURIComponent(sourceId)}&type=stored`
        });
        const contentType = resp.headers.get("content-type") || "";
        if (contentType.includes("application/json")) {
          const data = await resp.json();
          throw new Error(data.error || "backend error");
        }
        const text = await resp.text();
        triggerDownload(text, `${sourceId}.txt`);
        flash(`Downloaded stored file for ${source.label || source.id}.`, "good");
      } catch (err) {
        flash(`Stored file download failed: ${err.message}`, "bad");
      } finally {
        setBusy(button, false);
        endForegroundTask();
      }
    }

    const scriptEditorSaved = { label: "", url: "", maxTargets: "5000", code: "" };

    function scriptEditorDirty() {
      return (
        document.getElementById("scriptEditorLabel").value !== scriptEditorSaved.label ||
        document.getElementById("scriptEditorUrl").value !== scriptEditorSaved.url ||
        document.getElementById("scriptEditorMaxTargets").value !== scriptEditorSaved.maxTargets ||
        document.getElementById("scriptEditorCode").value !== scriptEditorSaved.code
      );
    }

    function updateScriptEditorDirtyState() {
      const dirty = scriptEditorDirty();
      const indicator = document.getElementById("scriptEditorDirtyIndicator");
      const revertBtn = document.getElementById("scriptEditorRevertBtn");
      if (indicator) indicator.style.display = dirty ? "" : "none";
      if (revertBtn) revertBtn.style.display = (dirty && scriptEditorSaved.code) ? "" : "none";
    }

    function revertScriptEditor() {
      document.getElementById("scriptEditorLabel").value = scriptEditorSaved.label;
      document.getElementById("scriptEditorUrl").value = scriptEditorSaved.url;
      document.getElementById("scriptEditorMaxTargets").value = scriptEditorSaved.maxTargets;
      document.getElementById("scriptEditorCode").value = scriptEditorSaved.code;
      document.getElementById("scriptEditorOutput").textContent = "Reverted to saved version.";
      updateScriptEditorDirtyState();
    }

    function openScriptEditor(sourceId) {
      const isNew = !sourceId;
      const source = sourceId ? externalSourceById(sourceId) : null;
      const hasScript = !!source?.has_script;
      document.getElementById("scriptEditorTitle").textContent = isNew ? "Add External Source"
        : hasScript ? "Edit External Source" : "Create Script for External Source";
      document.getElementById("scriptEditorId").value = sourceId || "";
      document.getElementById("scriptEditorId").disabled = !isNew;
      document.getElementById("scriptEditorLabel").value = (!isNew && !hasScript && source) ? (source.label || "") : "";
      document.getElementById("scriptEditorUrl").value = (!isNew && !hasScript && source) ? (source.url || "") : "";
      document.getElementById("scriptEditorMaxTargets").value = source?.max_targets || "5000";
      document.getElementById("scriptEditorCode").value = "";
      document.getElementById("scriptEditorOutput").textContent = isNew
        ? "Fill in the fields and paste a Python script."
        : hasScript ? "Loading saved script..."
        : "This source uses the bundled parser. Paste a custom Python script to replace it.";
      document.getElementById("scriptEditorDeleteBtn").style.display = hasScript ? "" : "none";
      document.getElementById("scriptEditorDeleteBtn").dataset.sourceId = sourceId || "";
      scriptEditorSaved.label = (!isNew && !hasScript && source) ? (source.label || "") : "";
      scriptEditorSaved.url = (!isNew && !hasScript && source) ? (source.url || "") : "";
      scriptEditorSaved.maxTargets = source?.max_targets || "5000";
      scriptEditorSaved.code = "";
      updateScriptEditorDirtyState();
      const modal = document.getElementById("scriptEditorModal");
      modal.classList.add("show");
      modal.setAttribute("aria-hidden", "false");

      if (!isNew && hasScript) {
        loadScriptForEditing(sourceId);
      }
    }

    function closeScriptEditor() {
      const modal = document.getElementById("scriptEditorModal");
      modal.classList.remove("show");
      modal.setAttribute("aria-hidden", "true");
    }

    async function loadScriptForEditing(sourceId) {
      try {
        const data = await callApi(rulesApi, "read_external_script", { source_id: sourceId }, { timeoutMs: 30000 });
        if (data.ok === false) { throw new Error(data.error || "backend error"); }
        document.getElementById("scriptEditorLabel").value = data.label || "";
        document.getElementById("scriptEditorUrl").value = data.url || "";
        document.getElementById("scriptEditorMaxTargets").value = data.max_targets || "5000";
        document.getElementById("scriptEditorCode").value = data.script_text || "";
        scriptEditorSaved.label = data.label || "";
        scriptEditorSaved.url = data.url || "";
        scriptEditorSaved.maxTargets = String(data.max_targets || "5000");
        scriptEditorSaved.code = data.script_text || "";
        document.getElementById("scriptEditorOutput").textContent = "Saved script loaded. Edit and Validate & Save, or close to discard changes.";
        updateScriptEditorDirtyState();
      } catch (err) {
        document.getElementById("scriptEditorOutput").textContent = `Failed to load script: ${err.message}`;
      }
    }

    async function saveExternalScript() {
      const sourceId = document.getElementById("scriptEditorId").value.trim();
      const label = document.getElementById("scriptEditorLabel").value.trim();
      const url = document.getElementById("scriptEditorUrl").value.trim();
      const maxTargets = document.getElementById("scriptEditorMaxTargets").value.trim();
      const scriptText = document.getElementById("scriptEditorCode").value;
      const outputEl = document.getElementById("scriptEditorOutput");
      const saveBtn = document.getElementById("scriptEditorSaveBtn");

      if (!sourceId) { flash("Source ID is required.", "bad"); return; }
      if (!/^[a-z0-9_]+$/.test(sourceId)) { flash("Source ID: lowercase letters, digits, underscores only.", "bad"); return; }
      if (!url) { flash("Source URL is required.", "bad"); return; }
      if (!scriptText.trim()) { flash("Script text is required.", "bad"); return; }

      outputEl.textContent = "Validating script on the router (15s timeout)...";
      setBusy(saveBtn, true);
      beginForegroundTask(`Validating and saving ${label || sourceId}...`, RULES_EXTERNAL_VALIDATE_TIMEOUT_MS, "rules");
      try {
        const data = await callApi(rulesApi, "save_external_script", {
          source_id: sourceId, label, url, script_text: scriptText, max_targets: maxTargets
        }, { timeoutMs: RULES_EXTERNAL_VALIDATE_TIMEOUT_MS });
        if (data.ok === false) { throw new Error(data.error || "Save failed"); }
        scriptEditorSaved.label = label;
        scriptEditorSaved.url = url;
        scriptEditorSaved.maxTargets = maxTargets;
        scriptEditorSaved.code = scriptText;
        updateScriptEditorDirtyState();
        outputEl.textContent = `Saved. Validation passed: ${data.validated_lines || "?"} lines.`;
        flash(`Script ${sourceId} saved and validated.`, "good");
        closeScriptEditor();
        await refreshRules(false, true);
      } catch (err) {
        outputEl.textContent = `Validation/save failed: ${err.message}`;
        flash(`Script save failed: ${err.message}`, "bad");
      } finally {
        setBusy(saveBtn, false);
        endForegroundTask();
      }
    }

    async function deleteExternalScript(sourceId) {
      if (!confirm(`Delete external source "${sourceId}" and its stored file?`)) return;
      beginForegroundTask(`Deleting ${sourceId}...`, 30000, "rules");
      try {
        const data = await callApi(rulesApi, "delete_external_script", { source_id: sourceId }, { timeoutMs: 30000 });
        if (data.ok === false) { throw new Error(data.error || "Delete failed"); }
        flash(`Source ${sourceId} deleted.`, "good");
        closeScriptEditor();
        await refreshRules(false, true);
      } catch (err) {
        flash(`Delete failed: ${err.message}`, "bad");
      } finally {
        endForegroundTask();
      }
    }

    async function runExternalSource(button) {
      if (state.rulesConfigDirty) {
        flash("Save Git and managed-source settings before refreshing external files.", "bad");
        document.getElementById("rulesExternalPreviewOutput").textContent = "Save Git and managed-source settings before refreshing external files.";
        return;
      }
      beginForegroundTask("Refreshing managed source snapshots in the background and applying changed routing targets if needed...", RULES_EXTERNAL_RUN_TIMEOUT_MS, "rules");
      setBusy(button, true);
      try {
        const data = await callApi(rulesApi, "sync_external_source", null, { timeoutMs: RULES_STATUS_TIMEOUT_MS });
        if (data.ok === false) {
          throw new Error(data.error || "backend error");
        }
        state.rules = data;
        renderRules(data);
        const finalData = data.ui_job_state === "running"
          ? await waitForRulesJob("Refreshing managed source files", RULES_EXTERNAL_RUN_TIMEOUT_MS, data.ui_job_id || "")
          : data;
        state.rules = finalData;
        renderRules(finalData);
        await refreshAll(false, false, true);
        flash(finalData.last_external_message || finalData.sync_phase_message || "External source import finished.", "good");
      } catch (err) {
        document.getElementById("rulesExternalPreviewOutput").textContent = formatRulesJobFailureDetails(err.routerJob || state.rules, `External source import failed: ${err.message}`);
        flash(`External source import failed: ${err.message}`, "bad");
      } finally {
        setBusy(button, false);
        endForegroundTask();
      }
    }

    async function backgroundSmokeRefresh() {
      const pathEl = document.getElementById("pathActive");
      const pathHint = document.getElementById("pathActiveHint");
      if (pathEl) { pathEl.textContent = "checking\u2026"; pathEl.className = "value"; }
      if (pathHint) { pathHint.textContent = "Running a quick smoke test to verify the transparent path after sync."; }
      try {
        const data = await callApi(runtimeApi, "smoke", null, { timeoutMs: 45000 });
        const smokeStatus = data.status || (data.ok ? "ok" : "error");
        state.runtime = {
          ...(state.runtime || {}),
          last_smoke_at: String(Math.floor(Date.now() / 1000)),
          last_smoke_status: smokeStatus,
          last_smoke_message: data.message || "",
          last_smoke_https_ok: !!data.https_ok,
          last_smoke_egress_ok: !!data.egress_ok,
          last_smoke_openai_ok: !!data.openai_ok,
          path_state: data.ok ? "active" : "degraded",
          path_degraded: !data.ok
        };
        renderRuntime(state.runtime);
      } catch (_) {
        await refreshAll(false, false, true).catch(() => {});
      }
    }

    async function runSmoke() {
      beginForegroundTask("Running live smoke test...", 45000);
      document.getElementById("smokeOutput").textContent = "Running smoke test...";
      try {
        const data = await callApi(runtimeApi, "smoke", null, { timeoutMs: 45000 });
        const smokeStatus = data.status || (data.ok ? "ok" : "error");
        const out = [
          `Smoke status: ${smokeStatus}`,
          data.message || "",
          "",
          `HTTPS probe: ${data.https_ok ? "ok" : "failed"}`,
          `Egress probe: ${data.egress_ok ? "ok" : "failed"}`,
          `OpenAI probe: ${data.openai_ok ? "ok" : "failed"}`,
          "",
          "=== https test (example.com) ===",
          data.https_test || "(empty)",
          "",
          "=== egress ip (ipinfo.io/ip) ===",
          data.egress || "(empty)",
          "",
          "=== openai api ===",
          data.openai_api || "(empty)"
        ].filter(Boolean).join("\n");
        document.getElementById("smokeOutput").textContent = out;
        state.runtime = {
          ...(state.runtime || {}),
          last_smoke_at: String(Math.floor(Date.now() / 1000)),
          last_smoke_status: smokeStatus,
          last_smoke_message: data.message || "",
          last_smoke_https_ok: !!data.https_ok,
          last_smoke_egress_ok: !!data.egress_ok,
          last_smoke_openai_ok: !!data.openai_ok
        };
        renderRuntime(state.runtime);
        flash(data.ok ? "Smoke test finished." : `Smoke test failed: ${data.message || "proxy path check failed."}`, data.ok ? "good" : "bad");
      } catch (err) {
        document.getElementById("smokeOutput").textContent = `Smoke test failed: ${err.message}`;
        flash(`Smoke test failed: ${err.message}`, "bad");
      } finally {
        endForegroundTask();
      }
    }

    async function recoverPath(button) {
      beginForegroundTask("Recovering Xray path...", 45000);
      setBusy(button, true);
      try {
        const data = await callApi(runtimeApi, "recover", null, { timeoutMs: 45000 });
        if (data.ok === false) {
          throw new Error(data.error || "backend error");
        }
        state.runtime = data.status || data;
        renderRuntime(state.runtime);
        flash("Recovery requested. Client traffic stays blocked until the Xray path is active.", "good");
      } catch (err) {
        flash(`Recovery failed: ${err.message}`, "bad");
      } finally {
        setBusy(button, false);
        endForegroundTask();
      }
    }

