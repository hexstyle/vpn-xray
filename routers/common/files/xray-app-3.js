    function renderManagedKey(profile) {
      const mode = profile.auth_mode || "managed_key";
      const parts = [
        `Auth mode: ${mode}`,
        `Managed key: ${profile.managed_key_present ? "present" : "missing"}`,
        `Bootstrap key: ${profile.bootstrap_key_present ? "present" : "not set"}`,
        `Managed key path: ${profile.managed_key_path || "(unset)"}`
      ];
      document.getElementById("managedKeyMeta").textContent = parts.join(" | ");
      document.getElementById("managedPubkeyOutput").textContent = profile.managed_pubkey || "(managed key not generated yet)";
    }

    // The dedicated "Last VPS Read Result" pane was removed in favor of
    // the Diagnose & Repair pipeline's raw_log. Live State cards and
    // Remote Info still render the same numbers, so this helper is now
    // a no-op we keep only so existing callers don't need edits.
    function renderCheckSummary(_profile) {
      /* intentionally empty */
    }

    function renderRemoteInfo(profile) {
      const remote = profile.remote_cache || {};
      const rows = [
        ["VPS profile", profile.vps_profile || "(unknown)"],
        ["Selected host", profile.endpoint_host || "(unknown)"],
        ["Router profile ready", state.runtime?.config_ready ? "yes" : "no"],
        ["Last read", `${remote.status || profile.last_inspect_status || "never"}${profile.last_inspect_at ? ` at ${formatUnixTime(profile.last_inspect_at)}` : ""}`],
        ["Router client", state.runtime?.xray_running ? "running" : "stopped"],
        ["Transparent path", state.runtime?.path_state === "degraded" ? "degraded" : (state.runtime?.path_active ? "active" : "inactive")],
        ["Last smoke", state.runtime?.last_smoke_status ? `${state.runtime.last_smoke_status}${state.runtime.last_smoke_at ? ` at ${formatUnixTime(state.runtime.last_smoke_at)}` : ""}` : "never"],
        ["SSH OK", remote.ssh_ok || "0"],
        ["Public IP", remote.public_ip || "(unknown)"],
        ["Host / FQDN", [remote.hostname, remote.fqdn].filter(Boolean).join(" | ") || "(unknown)"],
        ["OS", remote.pretty_name || "(unknown)"],
        ["Xray", remote.xray_present === "1" ? `present | ${remote.xray_version || "version unknown"}` : "not installed"],
        ["Xray service", remote.xray_service || "(unknown)"],
        ["Configured Xray port", remote.server_port || "(unknown)"],
        ["Selected-port listener", remote.listener_port ? "present" : "missing"],
        ["Install support", remote.install_supported === "1" ? `supported: ${remote.install_notes || ""}` : `not supported: ${remote.install_notes || ""}`]
      ];
      document.getElementById("remoteInfoGrid").innerHTML = rows.map(([key, value]) => (
        `<div>${escapeHtml(key)}</div><div class="mono">${escapeHtml(value)}</div>`
      )).join("");

      let ipinfoPretty = remote.ipinfo_json || "No inspection data yet.";
      try {
        const parsed = JSON.parse(remote.ipinfo_json || "{}");
        const summary = [
          parsed.ip && `ip: ${parsed.ip}`,
          parsed.city && `city: ${parsed.city}`,
          parsed.region && `region: ${parsed.region}`,
          parsed.country && `country: ${parsed.country}`,
          parsed.org && `org: ${parsed.org}`,
          parsed.loc && `loc: ${parsed.loc}`,
          parsed.timezone && `timezone: ${parsed.timezone}`
        ].filter(Boolean);
        if (summary.length) {
          ipinfoPretty = `${summary.join("\n")}\n\nraw:\n${JSON.stringify(parsed, null, 2)}`;
        }
      } catch (err) {
      }
      document.getElementById("ipinfoOutput").textContent = ipinfoPretty;
    }

    function compareValue(value, matches) {
      const safeValue = value === "" ? "(empty)" : value || "(empty)";
      return `
        <div class="compare-value">
          <div class="mono">${escapeHtml(safeValue)}</div>
          <span class="diff-badge ${matches ? "" : "diff"}">${matches ? "match" : "differs"}</span>
        </div>
      `;
    }

    function renderCompareTables(profile) {
      const router = state.vps?.router_current || {};
      const remote = profile.remote_cache || {};
      const desiredHtml = compareFields.map((field) => (
        `<tr><th>${escapeHtml(field.label)}</th><td>${compareValue(profile[field.key] || "", true)}</td></tr>`
      )).join("");
      const routerHtml = compareFields.map((field) => {
        const desired = profile[field.key] || "";
        if (!field.routerKey) {
          return `<tr><th>${escapeHtml(field.label)}</th><td>${compareValue("(not stored on router)", true)}</td></tr>`;
        }
        const current = router[field.routerKey] || "";
        return `<tr><th>${escapeHtml(field.label)}</th><td>${compareValue(current, desired === current)}</td></tr>`;
      }).join("");
      const remoteHtml = compareFields.map((field) => {
        const desired = profile[field.key] || "";
        const current = field.remoteKey ? (remote[field.remoteKey] || "") : "(not applicable on VPS)";
        const matches = field.remoteKey ? desired === current : true;
        return `<tr><th>${escapeHtml(field.label)}</th><td>${compareValue(current, matches)}</td></tr>`;
      }).join("");
      document.getElementById("desiredCompare").innerHTML = desiredHtml;
      document.getElementById("routerCompare").innerHTML = routerHtml;
      document.getElementById("remoteCompare").innerHTML = remoteHtml;
    }

    function directRouterVsRemoteDiff(profile) {
      const router = state.vps?.router_current || {};
      const remote = profile.remote_cache || {};
      const diffs = [];
      compareFields.forEach((field) => {
        if (!field.routerKey || !field.remoteKey) return;
        const routerValue = router[field.routerKey] || "";
        const remoteValue = remote[field.remoteKey] || "";
        if (routerValue !== remoteValue) {
          diffs.push(field.label);
        }
      });
      return diffs;
    }

    function renderSyncOverview(profile) {
      const routerDiff = parseDiffList(profile.router_diff);
      const remoteDiff = parseDiffList(profile.remote_diff);
      const routerVsRemote = directRouterVsRemoteDiff(profile);
      const chips = [
        `<span class="chip ${routerDiff.length ? "bad" : "ok"}">Router: ${escapeHtml(routerDiff.length ? routerDiff.join(", ") : "match")}</span>`,
        `<span class="chip ${remoteDiff.length ? "bad" : "ok"}">VPS: ${escapeHtml(remoteDiff.length ? remoteDiff.join(", ") : "match")}</span>`,
        `<span class="chip ${routerVsRemote.length ? "bad" : "ok"}">Router vs VPS: ${escapeHtml(routerVsRemote.length ? routerVsRemote.join(", ") : "match")}</span>`
      ];
      document.getElementById("syncChips").innerHTML = chips.join("");
    }

    function renderRules(data) {
      const rulesTextIncluded = !!data.rules_text_included;
      const gitSyncEnabled = !!data.git_sync_enabled;
      const gitConfigured = !!data.git_configured;
      const gitReadonly = !!data.git_readonly;
      const gitPushReady = !!data.git_push_ready;
      const gitPushBlocked = gitSyncEnabled && !gitPushReady;
      const repoReady = !!data.repo_ready;
      const externalSources = Array.isArray(data.external_sources) ? data.external_sources : [];
      const enabledExternalSources = externalSources.filter((item) => !!item.enabled);
      const dueExternalSources = enabledExternalSources.filter((item) => !!item.due);
      const externalEnabled = !!data.external_source_enabled;
      const externalDue = !!data.external_source_due;
      const mode = effectiveRulesMode(data);
      const uiJobState = data.ui_job_state || "";
      const uiJobKind = data.ui_job_kind || "";
      const uiJobMessage = data.ui_job_message || "";
      const uiJobStartedAt = data.ui_job_started_at ? ` · ${formatUnixTime(data.ui_job_started_at)}` : "";
      const uiJobFinishedAt = data.ui_job_finished_at ? ` · ${formatUnixTime(data.ui_job_finished_at)}` : "";
      const uiJobRunning = uiJobState === "running";
      const modePending = !!state.pendingRulesMode || (uiJobRunning && uiJobKind === "set_mode");
      const intervalSeconds = Number(data.sync_interval || 0) || 30;
      const externalIntervalSeconds = Number(data.external_source_interval || 0) || 3600;
      const lastSyncStatus = data.last_sync_status || "never";
      const lastSyncAt = data.last_sync_at ? ` · ${formatUnixTime(data.last_sync_at)}` : "";
      const lastRemoteProbeStatus = data.last_remote_probe_status || "never";
      const lastRemoteProbeAt = data.last_remote_probe_at ? ` · ${formatUnixTime(data.last_remote_probe_at)}` : "";
      const gitHealth = deriveRulesGitHealth(data);
      const gitHealthDetail = gitHealth.detail || "(no detail)";
      const syncStrategy = rulesSyncStrategyLabel(data.last_sync_strategy || "");
      const lastExternalStatus = data.last_external_status || "never";
      const lastExternalAt = data.last_external_run_at ? ` · ${formatUnixTime(data.last_external_run_at)}` : "";
      const lastCutoverStatus = data.last_cutover_status || "never";
      const lastCutoverAt = data.last_cutover_at ? ` · ${formatUnixTime(data.last_cutover_at)}` : "";
      const cutoverRequired = !!data.cutover_required;
      const phase = data.sync_phase || "unknown";
      const phaseAt = data.sync_phase_at ? ` · ${formatUnixTime(data.sync_phase_at)}` : "";
      const syncActor = data.sync_actor || data.last_sync_actor || "unknown";
      const trace = (data.sync_trace || "").split(" || ").filter(Boolean);
      const counts = `${data.source_count || 0} manual / ${data.managed_source_count || 0} managed-stored / ${data.managed_applied_source_count || 0} managed-applied / ${data.effective_source_count || 0} effective / ${data.domain_count || 0} domains / ${data.literal_count || 0} literal / ${data.resolved_count || 0} resolved-snapshot / ${data.xray_ipset_count || 0} live-set`;
      const phaseLabels = {
        checking_remote: "Checking Git and local state",
        drift_detected: "Changes found, reset is about to start",
        cutover_in_progress: "Reset is in progress",
        verified: "Everything is current",
        error: "Sync failed"
      };
      const currentPhase = phaseLabels[phase] || phase;
      const runtimeState = cutoverRequired
        ? "Changes are applied in config, but old connections may still be alive until reset finishes."
        : "Current rules are active on the router.";
      const statusRows = [
        ["UI operation", uiJobState ? `${uiJobKind || "operation"}: ${uiJobState}${uiJobRunning ? uiJobStartedAt : uiJobFinishedAt}` : "idle"],
        ["UI operation detail", uiJobMessage || "(no active UI-triggered router operation)"],
        ["Git sync state", gitHealth.label],
        ["Git sync detail", gitHealthDetail],
        ["Git push state", gitPushReady ? "ready" : (data.git_push_status || "not ready")],
        ["Git push detail", data.git_push_message || "(no push detail)"],
        ["Git push fix", data.git_push_next_step || "(no action required)"],
        ["Background probe", gitSyncEnabled ? (gitConfigured ? `Every ${intervalSeconds}s · ${lastRemoteProbeStatus}${lastRemoteProbeAt}` : "Enabled, but still not ready for remote probes") : "Idle in local-only mode"],
        ["Managed source refresh", externalEnabled ? `Every ${externalIntervalSeconds}s · ${externalDue ? "due now" : "scheduled"}${lastExternalAt}` : "Background refresh disabled"],
        ["Remote rules file", data.remote_rules_ref || "(unknown)"],
        ["External status", externalEnabled ? `${lastExternalStatus}${lastExternalAt} · actor=${data.last_external_actor || "unknown"}` : "Disabled"],
        ["Current phase", `${currentPhase}${phaseAt}`],
        ["Phase detail", data.sync_phase_message || "(no detail)"],
        ["Sync status", `${lastSyncStatus}${lastSyncAt} · actor=${syncActor}`],
        ["Working copy strategy", syncStrategy],
        ["Runtime state", runtimeState],
        ["Last reset", `${lastCutoverStatus}${lastCutoverAt}`],
        ["Last verified", formatUnixTime(data.last_verified_at)]
      ];
      const diagnosticsLines = [
        `Git head: ${data.repo_head || "(none)"}`,
        `Rules checksum: ${shortSig(data.rules_checksum)}`,
        `Applied signature: ${shortSig(data.last_apply_signature)}`,
        `Cutover signature: ${shortSig(data.last_cutover_signature)}`,
        `Routing mode: ${mode}${modePending ? " (apply in progress)" : ""}`,
        `Git sync state: ${gitHealth.label}`,
        `Git sync detail: ${gitHealthDetail}`,
        `Git push state: ${gitPushReady ? "ready" : (data.git_push_status || "not ready")}`,
        `Git push detail: ${data.git_push_message || "(no push detail)"}`,
        `Git push fix: ${data.git_push_next_step || "(no action required)"}`,
        `Working copy strategy: ${syncStrategy}`,
        `Counts: ${counts}`,
        data.last_remote_probe_message ? `Remote probe: ${data.last_remote_probe_message}` : "",
        data.last_sync_message ? `Sync message: ${data.last_sync_message}` : "",
        data.last_external_message ? `External message: ${data.last_external_message}` : "",
        externalEnabled ? `External generated/additions: ${data.last_external_generated_count || 0}/${data.last_external_added_count || 0}` : "",
        data.last_cutover_message ? `Cutover message: ${data.last_cutover_message}` : "",
        data.ui_job_suggestion ? `Suggestion: ${data.ui_job_suggestion}` : "",
        ...(data.ui_job_console_output ? ["", "Console output:", ...String(data.ui_job_console_output).split("\n")] : []),
        "",
        trace.length ? "Recent activity:" : "Recent activity: (none yet)",
        ...trace.map((item) => `- ${item}`)
      ].filter((line, index, array) => line || (index > 0 && array[index - 1] !== ""));
      const repoLines = [
        `Git sync enabled: ${gitSyncEnabled ? "yes" : "no"}`,
        `Git configured: ${gitConfigured ? "yes" : "no"}`,
        `Repo path: ${data.repo_path || "(unknown)"}`,
        `Fetch URL: ${data.repo_fetch_url || "(local-only)"}`,
        `Remote rules ref: ${data.remote_rules_ref || "(unknown)"}`,
        `Remote browser URL: ${data.repo_browser_rules_url || "(not available)"}`,
        `Push URL: ${data.repo_push_url || "(reuse fetch URL)"}`,
        `Effective push URL: ${data.repo_push_url_effective || "(not available)"}`,
        `Rules file: ${data.rules_relpath || "(unknown)"}`,
        `Repo head: ${data.repo_head || "(none)"}`,
        `Sync interval: ${intervalSeconds}s`,
        `Repo dirty: ${data.repo_dirty ? "yes" : "no"}`,
        `Auth mode: ${data.git_auth_mode || "none"}`,
        `Access mode: ${gitPushReady ? "read-write" : "pull/apply only"}`,
        `Push policy: ${data.enable_push ? "enabled" : "disabled"}`,
        `Push auth: ${data.git_push_effective_auth || "(unknown)"}`,
        `Push path: ${gitPushReady ? "available through the Push button" : (data.git_push_message || "disabled until write auth is configured")}`,
        `Working copy strategy: ${syncStrategy}`,
        `Managed source files enabled: ${enabledExternalSources.length}/${externalSources.length}`,
        `External interval: ${externalIntervalSeconds}s`,
        `External due now: ${externalDue ? "yes" : "no"}`,
        `External last status: ${lastExternalStatus || "(never)"}`,
        `HTTPS username: ${data.git_http_username || "(not set)"}`,
        `HTTPS secret stored: ${data.git_http_password_set ? "yes" : "no"}`,
        `SSH key present: ${data.git_ssh_key_present ? "yes" : "no"}`,
        `Repo ready: ${repoReady ? "yes" : "no"}`
      ].filter(Boolean);
      const chips = [
        `<span class="chip ${gitHealth.chipClass}">Git: ${escapeHtml(gitHealth.label)}</span>`,
        `<span class="chip ${modePending ? "warn" : mode === "selective" ? "ok" : ""}">Mode: ${escapeHtml(mode)}${modePending ? " (applying)" : ""}</span>`,
        `<span class="chip">Rules: ${escapeHtml(counts)}</span>`,
      ];
      if (externalEnabled) {
        const errorSources = externalSources.filter((s) => s.health === "error");
        if (errorSources.length > 0) {
          const details = errorSources.map((s) => `${s.label || s.id}: ${s.last_message || "fetch failed"}`).join("\n");
          const names = errorSources.map((s) => s.label || s.id).join(", ");
          chips.push(`<span class="chip bad rules-external-error-chip" title="${escapeHtml(details)}" style="cursor:pointer;">${escapeHtml(names)}: error</span>`);
        }
      }
      if (state.rulesDirty) {
        chips.push(`<span class="chip bad">Unsaved edits</span>`);
      }
      if (gitPushBlocked) {
        chips.push(`<span class="chip warn">Push blocked</span>`);
      }

      document.getElementById("rulesSummaryChips").innerHTML = chips.join("");
      if (
        !rulesTextIncluded &&
        state.rulesTextLoaded &&
        !state.rulesDirty &&
        state.rulesTextChecksum &&
        data.rules_checksum &&
        state.rulesTextChecksum !== data.rules_checksum
      ) {
        state.rulesTextLoaded = false;
        state.rulesTextChecksum = "";
      }
      if (!state.rulesConfigDirty) {
        const externalSelection = {};
        externalSources.forEach((source) => {
          externalSelection[source.id] = !!source.enabled;
        });
        document.getElementById("rulesGitSyncEnabled").checked = gitSyncEnabled;
        document.getElementById("rulesEnablePush").checked = !!data.enable_push;
        document.getElementById("rulesRepoFetchUrl").value = data.repo_fetch_url || "";
        document.getElementById("rulesRepoPushUrl").value = data.repo_push_url || "";
        document.getElementById("rulesRepoBranch").value = data.repo_branch || "main";
        document.getElementById("rulesSyncInterval").value = data.sync_interval || "30";
        document.getElementById("rulesExternalInterval").value = data.external_source_interval || "86400";
        document.getElementById("rulesGitAuthMode").value = data.git_auth_mode || (gitSyncEnabled ? "auto" : "none");
        document.getElementById("rulesGitHttpUsername").value = data.git_http_username || "";
        document.getElementById("rulesGitHttpPassword").value = "";
        document.getElementById("rulesGitSshPrivateKey").value = "";
        renderExternalSources(externalSources, externalSelection);
      } else {
        renderExternalSources(externalSources, currentExternalSourceSelection());
      }
      document.getElementById("rulesGitSshPublicKey").textContent = data.git_ssh_public_key || "No router SSH key yet.";
      const gitActionPanel = document.getElementById("rulesGitActionPanel");
      if (gitActionPanel) {
        gitActionPanel.textContent = rulesGitPushActionText(data);
        gitActionPanel.className = `hint ${gitPushBlocked ? "warn" : gitPushReady ? "ok" : ""}`;
      }
      const gitBanner = document.getElementById("rulesGitStatusBanner");
      if (gitBanner) {
        if (!gitSyncEnabled) {
          gitBanner.innerHTML = "";
        } else {
          const bc = gitHealth.chipClass || "warn";
          const title = gitHealth.label || "unknown";
          let body = gitHealthDetail;
          if (bc !== "ok" && data.git_push_next_step) {
            body += `\nNext step: ${data.git_push_next_step}`;
          }
          gitBanner.innerHTML = `<div class="status-banner ${escapeHtml(bc)}"><div class="status-banner-title">${escapeHtml(title)}</div><div class="status-banner-body">${escapeHtml(body)}</div></div>`;
        }
      }
      const gitSyncStateText = document.getElementById("rulesGitSyncStateText");
      if (gitSyncStateText) {
        gitSyncStateText.textContent = gitSyncEnabled
          ? `Git sync: ${gitHealth.label}. ${gitHealthDetail}`
          : "Git sync is disabled.";
        gitSyncStateText.className = `toggle-state ${gitSyncEnabled ? gitHealth.chipClass : ""}`;
      }
      const externalPreviewOutput = document.getElementById("rulesExternalPreviewOutput");
      if (externalPreviewOutput) {
        if (uiJobKind === "sync_external_source" && uiJobRunning) {
          externalPreviewOutput.textContent = [
            "Managed source refresh is running on the router.",
            `Started: ${formatUnixTime(data.ui_job_started_at)}`,
            `Detail: ${uiJobMessage || data.sync_phase_message || "Waiting for the router to report progress..."}`,
            "",
            `Routing-enabled managed files: ${enabledExternalSources.length}/${externalSources.length}`,
            `Previous result: ${lastExternalStatus}${lastExternalAt}`,
            data.last_external_message || "No previous external source output yet."
          ].join("\n");
        } else if (uiJobKind === "sync_external_source" && uiJobState === "error") {
          externalPreviewOutput.textContent = [
            "Last managed source refresh failed.",
            `Finished: ${formatUnixTime(data.ui_job_finished_at)}`,
            `Error: ${uiJobMessage || data.last_external_message || "Unknown router-side failure."}`,
            "",
            `Routing-enabled managed files: ${enabledExternalSources.length}/${externalSources.length}`,
            `Stored targets now: ${data.managed_source_count || 0}`
          ].join("\n");
        } else if (lastExternalStatus === "running") {
          externalPreviewOutput.textContent = [
            "Managed source refresh is running in the background on the router.",
            `Started: ${lastExternalAt ? lastExternalAt.replace(/^ · /, "") : "unknown"}`,
            `Detail: ${data.last_external_message || "Waiting for the router to finish the scheduled snapshot refresh..."}`,
            "",
            `Routing-enabled managed files: ${enabledExternalSources.length}/${externalSources.length}`,
            `Stored targets now: ${data.managed_source_count || 0}`
          ].join("\n");
        } else {
          externalPreviewOutput.textContent = [
            `Last status: ${lastExternalStatus}${lastExternalAt}`,
            `Routing-enabled managed files: ${enabledExternalSources.length}/${externalSources.length}`,
            `Generated targets: ${data.last_external_generated_count || 0}`,
            `Added targets: ${data.last_external_added_count || 0}`,
            "",
            data.last_external_message || "No external source output yet."
          ].join("\n");
        }
      }
      renderRulesModeUi(data);
      if (!state.rulesDirty) {
        const editor = document.getElementById("rulesText");
        if (rulesTextIncluded) {
          editor.value = data.rules_text || "";
          state.rulesEditorBaseHead = data.repo_head || "";
          state.rulesTextLoaded = true;
          state.rulesTextChecksum = data.rules_checksum || "";
        } else if (!state.rulesTextLoaded) {
          editor.value = "";
          state.rulesEditorBaseHead = data.repo_head || "";
        }
      }
      document.getElementById("rulesStatusGrid").innerHTML = statusRows.map(([key, value]) => (
        `<div>${escapeHtml(key)}</div><div class="mono">${escapeHtml(value)}</div>`
      )).join("");
      document.getElementById("rulesTraceOutput").textContent = diagnosticsLines.join("\n");
      document.getElementById("rulesRepoDetails").textContent = repoLines.join("\n");
      updateRulesConfigUi();
      updateRulesActionState();
      ensureRulesJobPolling(data);
    }

    function updateRulesActionState() {
      const applyButton = document.getElementById("rulesApplyBtn");
      const pullButton = document.getElementById("rulesPullBtn");
      const pushButton = document.getElementById("rulesPushBtn");
      const hint = document.getElementById("rulesEditorHint");
      const loadButton = document.getElementById("rulesLoadTextBtn");
      const runtimeSwitchOn = state.runtime?.switch_state === "on";
      const selectiveMode = effectiveRulesMode(state.rules) === "selective";
      const gitSyncEnabled = !!state.rules?.git_sync_enabled;
      const gitConfigured = !!state.rules?.git_configured;
      const gitReadonly = rulesGitReadonlyLive();
      const gitPushReady = !!state.rules?.git_push_ready;
      const gitPushBlocked = rulesGitPushBlockedLive();
      const backendJobRunning = rulesJobIsRunning(state.rules);
      const workingCopyDetail = rulesWorkingCopyDetail(state.rules);
      const editor = document.getElementById("rulesText");
      if (applyButton) {
        applyButton.textContent = state.rulesDirty ? "Save Local + Apply" : "Apply Local Rules";
        applyButton.disabled = state.foregroundBusy || backendJobRunning;
        applyButton.title = "";
      }
      if (pullButton) {
        pullButton.textContent = state.rulesDirty ? "Pull + Merge Into Local" : "Pull From Git";
        pullButton.disabled = state.foregroundBusy || backendJobRunning || !gitConfigured;
        pullButton.title = gitConfigured
          ? ""
          : "Configure and validate Git sync first.";
      }
      if (pushButton) {
        pushButton.textContent = state.rulesDirty ? "Save + Push To Git" : "Push To Git";
        pushButton.disabled = state.foregroundBusy || backendJobRunning || !gitSyncEnabled || !gitConfigured || !gitPushReady;
        pushButton.title = !gitConfigured
          ? "Configure and validate Git sync first."
          : gitPushBlocked
          ? rulesGitPushActionText(state.rules)
          : "";
      }
      if (editor) {
        editor.readOnly = !state.rulesTextLoaded;
        editor.placeholder = state.rulesTextLoaded
          ? ""
          : "The full shared rules list is not auto-loaded after large imports. Click 'Load Current List' before editing.";
        editor.title = !state.rulesTextLoaded
          ? "Load the current shared rules list before editing so the UI does not overwrite a large router-side file blindly."
          : workingCopyDetail;
      }
      if (loadButton) {
        loadButton.textContent = state.rulesTextLoaded ? "Reload Current List" : "Load Current List";
        loadButton.disabled = state.foregroundBusy || state.rulesBusy || backendJobRunning;
      }
      if (hint) {
        const applyScope = runtimeSwitchOn && selectiveMode
          ? "These addresses are active right now because the GL.iNet VPN switch is ON and Routing Mode is selective."
          : "These addresses will only affect traffic after the GL.iNet VPN switch is ON and Routing Mode is selective.";
        if (!state.rulesTextLoaded) {
          hint.textContent = `Live status stays lightweight after large imports, so the full shared list is not auto-loaded into the editor. Click 'Load Current List' before editing or saving text changes. ${applyScope}`;
        } else if (gitReadonly) {
          hint.textContent = state.rulesDirty
            ? `You have unsaved local edits in the router working copy. Pull merges the fetched Git file into it while keeping unique local rules. Push is blocked: ${state.rules?.git_push_message || "write access is not configured."} ${workingCopyDetail} ${applyScope}`
            : `Git sync is active in pull/apply mode. Push is blocked: ${state.rules?.git_push_message || "write access is not configured."} Fix: ${state.rules?.git_push_next_step || "configure writable credentials."} ${workingCopyDetail} ${applyScope}`;
        } else if (!gitSyncEnabled || !gitConfigured) {
          hint.textContent = state.rulesDirty
            ? `You have unsaved local edits. Saving applies the local text list directly on this router without any Git sync. ${applyScope}`
            : `Git sync is disabled. The text area below is the authoritative local rules list for this router. ${applyScope}`;
        } else {
          hint.textContent = state.rulesDirty
            ? `You have unsaved local edits. Apply saves them only on this router. Pull merges the fetched Git file into the router working copy while preserving unique local rules. Push saves the working copy, preserves both unique sides of a conflict, and then pushes to Git. ${workingCopyDetail} ${applyScope}`
            : `This editor shows the router working copy of the shared list. Pull refreshes it from Git while keeping unique local rules on conflict. Push commits the current working copy after preserving both unique sides of a conflict. Comment-only edits no longer trigger a full runtime reset. ${workingCopyDetail} ${applyScope}`;
        }
      }
    }

