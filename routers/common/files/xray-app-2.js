    function deriveRulesGitHealth(data = state.rules) {
      const gitSyncEnabled = !!data?.git_sync_enabled;
      const gitConfigured = !!data?.git_configured;
      const repoReady = !!data?.repo_ready;
      const gitReadonly = !!data?.git_readonly;
      const pushReady = !!data?.git_push_ready;
      const uiJobRunning = data?.ui_job_state === "running" && ["sync_rules", "pull_rules", "push_rules", "sync_external_source"].includes(data?.ui_job_kind || "");
      const intervalSeconds = Number(data?.sync_interval || 0) || 30;
      const probeStatus = data?.last_remote_probe_status || "";
      const probeMessage = data?.last_remote_probe_message || "";
      const probeAt = Number(data?.last_remote_probe_at || 0);
      const probeAgeSeconds = probeAt > 0 ? Math.max(0, Math.floor(Date.now() / 1000) - probeAt) : Number.POSITIVE_INFINITY;
      const probeStaleAfterSeconds = Math.max(intervalSeconds * 2, 120);
      const updateAvailable = !!data?.last_remote_probe_update_available;
      const lastSyncStatus = data?.last_sync_status || "";
      const lastSyncMessage = data?.last_sync_message || "";
      const phase = data?.sync_phase || "";
      const phaseMessage = data?.sync_phase_message || "";
      const cutoverRequired = !!data?.cutover_required;
      const selectiveFallback = !!data?.selective_fallback_active;
      const selectiveFallbackReason = data?.selective_fallback_reason || "";

      // Selective→FULL fallback takes precedence: the user asked for
      // selective routing, the install activated FULL temporarily because
      // the rules repo was unreachable, and the background loop is now
      // retrying. Surface that as a hard error until selective is back.
      if (selectiveFallback) {
        return {
          chipClass: "bad",
          label: "selective pending",
          detail: `Selective routing requested but the rules repository is unreachable. Currently routing in FULL mode. Cause: ${selectiveFallbackReason || "rules sync failed"}. The router retries every sync interval and switches back automatically when the repository is reachable.`
        };
      }

      if (!gitSyncEnabled) {
        return { chipClass: "", label: "local-only", detail: "Git sync is disabled. The router is using only the local rules list." };
      }
      if (!gitConfigured || !repoReady || !(data?.repo_fetch_url || "")) {
        return {
          chipClass: "bad",
          label: "not ready",
          detail: lastSyncMessage || "Git sync is enabled, but the repository URL or local clone is missing."
        };
      }
      if (uiJobRunning) {
        return {
          chipClass: "warn",
          label: "sync running",
          detail: data?.ui_job_message || "A router-side sync job is still running."
        };
      }
      if (probeStatus === "timeout") {
        return {
          chipClass: "bad",
          label: "probe timeout",
          detail: probeMessage || "Git remote probe did not finish within 5 seconds. This looks like a network problem."
        };
      }
      if (probeStatus === "error") {
        return {
          chipClass: "bad",
          label: "probe failed",
          detail: probeMessage || "Git remote probe failed."
        };
      }
      if (!Number.isFinite(probeAgeSeconds) || probeAgeSeconds > probeStaleAfterSeconds) {
        return {
          chipClass: "bad",
          label: "probe stale",
          detail: probeAt > 0
            ? `The background Git probe has not reported for ${probeAgeSeconds}s. The scheduler is stuck, blocked, or the router lost network access.`
            : "The background Git probe has never reported. The scheduler has not completed a first successful check yet."
        };
      }
      if (phase === "error" || lastSyncStatus === "error") {
        return {
          chipClass: "bad",
          label: "sync failed",
          detail: phaseMessage || lastSyncMessage || "Git sync failed."
        };
      }
      if (cutoverRequired) {
        return {
          chipClass: "bad",
          label: "diverged",
          detail: phaseMessage || "Config and active runtime ruleset are out of sync."
        };
      }
      if (updateAvailable) {
        return {
          chipClass: "warn",
          label: "update available",
          detail: probeMessage || "Remote repository has a newer rules commit."
        };
      }
      if (lastSyncStatus === "ok") {
        if (!pushReady) {
          return {
            chipClass: "warn",
            label: "ready (push blocked)",
            detail: data?.git_push_message || "Pull/apply are ready, but Push needs write configuration."
          };
        }
        return {
          chipClass: "ok",
          label: gitReadonly ? "ready (pull-only)" : "ready",
          detail: probeMessage || (gitReadonly
            ? "Git sync is healthy in pull-only mode. Pull is available, and Push stays disabled until write credentials are configured."
            : "Git sync is healthy. Pull is ready, and Push can be attempted explicitly from the UI.")
        };
      }
      return {
        chipClass: "warn",
        label: "unknown",
        detail: probeMessage || lastSyncMessage || "Git sync state is not fully known yet."
      };
    }

    function rulesGitReadonlyLive() {
      return !!state.rules?.git_readonly;
    }

    function rulesGitPushBlockedLive() {
      return !!state.rules?.git_sync_enabled && !state.rules?.git_push_ready;
    }

    function rulesGitPushActionText(data = state.rules) {
      if (!data?.git_sync_enabled) {
        return "Git sync is disabled. Push is not used in local-only mode.";
      }
      if (data?.git_push_ready) {
        return `Push is ready via ${data.git_push_effective_auth || data.git_auth_mode || "configured"} auth.`;
      }
      const lines = [
        `Push blocked: ${data?.git_push_message || "write access is not configured."}`,
        `Fix: ${data?.git_push_next_step || "Configure writable Git credentials, then save settings."}`
      ];
      if (data?.git_push_effective_auth === "ssh" || data?.git_auth_mode === "ssh") {
        lines.push("For GitHub SSH deploy keys: add the public key below to the target repository with write access enabled.");
      } else if (data?.git_push_effective_auth === "https" || data?.repo_push_url_effective?.startsWith("https://")) {
        lines.push("For GitHub HTTPS: use a token/password that can write to the repository.");
      }
      if (data?.git_ssh_public_key) {
        lines.push(`Router public key: ${data.git_ssh_public_key}`);
      }
      return lines.join("\n");
    }

    function rulesGitReadonlyProjected() {
      const syncEnabled = !!document.getElementById("rulesGitSyncEnabled")?.checked;
      const authMode = document.getElementById("rulesGitAuthMode")?.value || "none";
      const repoUrl = document.getElementById("rulesRepoFetchUrl")?.value.trim() || "";
      const pushEnabled = !!document.getElementById("rulesEnablePush")?.checked;
      const httpUsername = document.getElementById("rulesGitHttpUsername")?.value.trim() || "";
      const httpPassword = document.getElementById("rulesGitHttpPassword")?.value || "";

      if (!syncEnabled) {
        return false;
      }
      if (!pushEnabled) {
        return true;
      }

      switch (authMode) {
        case "none":
        case "readonly":
          return true;
        case "https":
        case "ssh":
          return false;
        default:
          break;
      }

      if (repoUrl.startsWith("git@") || repoUrl.startsWith("ssh://")) {
        return false;
      }
      if (repoUrl.startsWith("http://") || repoUrl.startsWith("https://")) {
        return !(httpUsername || httpPassword);
      }
      return rulesGitReadonlyLive();
    }

    function rulesSyncStrategyLabel(strategy) {
      switch (strategy || "") {
        case "remote":
          return "matches fetched Git file";
        case "exact-local":
          return "exact local working copy";
        case "merge-preserve-both":
          return "Git base + local unique rules";
        case "local-ahead":
          return "local copy ahead of fetched Git head";
        case "local-apply":
          return "local apply only";
        case "local-only":
          return "local-only";
        default:
          return strategy || "(unknown)";
      }
    }

    function rulesWorkingCopyDetail(data = state.rules) {
      switch (data?.last_sync_strategy || "") {
        case "remote":
          return "This editor currently matches the fetched Git file.";
        case "merge-preserve-both":
          return "This editor shows the router working copy. The last sync kept the Git file as the base and appended unique router-local rules.";
        case "local-ahead":
          return "This editor shows the router working copy, which currently has local edits ahead of the last fetched Git head.";
        default:
          return "This editor shows the router working copy of the shared list.";
      }
    }

    function renderRulesModeUi(data = state.rules) {
      const mode = effectiveRulesMode(data);
      const pending = !!state.pendingRulesMode || (data?.ui_job_state === "running" && data?.ui_job_kind === "set_mode");
      const modeToggle = document.getElementById("rulesModeToggle");
      if (modeToggle) {
        modeToggle.checked = mode === "selective";
      }
      const modeStateText = document.getElementById("rulesModeStateText");
      if (modeStateText) {
        if (pending) {
          modeStateText.textContent = mode === "selective"
            ? "Applying selective routing on this router..."
            : "Applying full routing on this router...";
          modeStateText.className = "toggle-state warn";
        } else {
          modeStateText.textContent = mode === "selective"
            ? "Selective routing is active on this router."
            : "Full routing is active on this router.";
          modeStateText.className = `toggle-state ${mode === "selective" ? "ok" : ""}`;
        }
      }
    }

    function rulesConfigPayload() {
      const payload = {
        git_sync_enabled: document.getElementById("rulesGitSyncEnabled").checked ? "1" : "0",
        repo_fetch_url: document.getElementById("rulesRepoFetchUrl").value.trim(),
        repo_push_url: document.getElementById("rulesRepoPushUrl").value.trim(),
        repo_branch: document.getElementById("rulesRepoBranch").value.trim(),
        enable_push: document.getElementById("rulesEnablePush").checked ? "1" : "0",
        sync_interval: document.getElementById("rulesSyncInterval").value.trim() || "30",
        external_source_enabled_ids: selectedExternalSourceIds().join(","),
        external_source_interval: document.getElementById("rulesExternalInterval").value.trim() || "86400",
        git_auth_mode: document.getElementById("rulesGitAuthMode").value,
        git_http_username: document.getElementById("rulesGitHttpUsername").value.trim()
      };
      const httpPassword = document.getElementById("rulesGitHttpPassword").value;
      const sshPrivateKey = document.getElementById("rulesGitSshPrivateKey").value.trim();
      if (httpPassword) {
        payload.git_http_password = httpPassword;
      }
      if (sshPrivateKey) {
        payload.git_ssh_private_key = sshPrivateKey;
      }
      return payload;
    }

    function maybeField(id) {
      return document.getElementById(id);
    }

    function setFieldVisible(wrapperId, visible) {
      const wrap = maybeField(wrapperId);
      if (wrap) {
        wrap.style.display = visible ? "" : "none";
      }
    }

    function updateAuthUi() {
      const mode = document.getElementById("authMode").value;
      setFieldVisible("authUserField", mode === "password" || mode === "private_key");
      setFieldVisible("authPasswordField", mode === "password");
      setFieldVisible("authPrivateKeyField", mode === "private_key");
      if (mode !== "password") {
        document.getElementById("sshPassword").value = "";
      }
      if (mode !== "private_key") {
        document.getElementById("bootstrapKey").value = "";
      }
    }

    function populateProfileSelect() {
      const select = document.getElementById("profileSelect");
      const current = state.vps?.active_profile_id || "";
      const profiles = Array.isArray(state.vps?.profiles) ? state.vps.profiles : [];
      if (!profiles.length) {
        select.innerHTML = `<option value="">No saved VPS profiles</option>`;
        select.value = "";
        return;
      }
      select.innerHTML = profiles.map((profile) => (
        `<option value="${escapeHtml(profile.id)}">${escapeHtml(profile.label || profile.id)} (${escapeHtml(profile.id)})</option>`
      )).join("");
      select.value = profiles.some((profile) => profile.id === current) ? current : profiles[0].id;
    }

    function populateVpsProfileSelect(currentValue) {
      const select = document.getElementById("vpsProfile");
      const profiles = Array.isArray(state.vps?.vps_profiles) ? state.vps.vps_profiles : [];
      if (!profiles.length) {
        select.innerHTML = `<option value="">No supported VPS profiles on router</option>`;
        select.value = "";
        return;
      }
      select.innerHTML = profiles.map((profile) => (
        `<option value="${escapeHtml(profile.id)}">${escapeHtml(profile.label || profile.id)}</option>`
      )).join("");
      const nextValue = profiles.some((profile) => profile.id === currentValue) ? currentValue : profiles[0].id;
      select.value = nextValue;
    }

    function populateProfileForm(profile, force = false) {
      if (!profile) return;
      if (!force && state.formDirty && formProfileId() === (profile.id || "")) {
        updateAuthUi();
        return;
      }
      document.getElementById("profileId").value = profile.id || "";
      populateVpsProfileSelect(profile.vps_profile || "");
      document.getElementById("profileLabel").value = profile.label || "";
      document.getElementById("authMode").value = profile.auth_mode || "managed_key";
      document.getElementById("vpsHost").value = profile.endpoint_host || profile.server_address || profile.ssh_host || "";
      document.getElementById("sshPort").value = profile.ssh_port || "";
      document.getElementById("sshUser").value = profile.ssh_user || "";
      document.getElementById("sshPassword").value = "";
      document.getElementById("serverPort").value = profile.server_port || "";
      document.getElementById("serverName").value = profile.server_name || "";
      document.getElementById("uuid").value = profile.uuid || "";
      document.getElementById("publicKey").value = profile.public_key || "";
      document.getElementById("shortId").value = profile.short_id || "";
      document.getElementById("flow").value = profile.flow || "";
      document.getElementById("bootstrapKey").value = "";
      clearDirty();
      updateAuthUi();
    }

    function formatUnixTime(ts) {
      if (!ts) return "never";
      const value = Number(ts);
      if (!Number.isFinite(value) || value <= 0) return String(ts);
      try {
        return new Date(value * 1000).toLocaleString();
      } catch (err) {
        return String(ts);
      }
    }

    function shortSig(value) {
      if (!value) return "(none)";
      const text = String(value);
      if (text.length <= 24) return text;
      return `${text.slice(0, 24)}...`;
    }

    function renderRuntime(data) {
      document.getElementById("switchState").textContent = data.switch_state || "unknown";
      document.getElementById("switchState").className = `value ${data.switch_state === "on" ? "ok" : data.switch_state === "off" ? "warn" : "bad"}`;
      document.getElementById("switchRequest").textContent = data.switch_state === "on" ? "path should be on" : data.switch_state === "off" ? "path should be off" : "unknown";
      document.getElementById("switchRequest").className = `value ${data.switch_state === "on" ? "ok" : data.switch_state === "off" ? "warn" : "bad"}`;

      const ready = !!data.config_ready;
      document.getElementById("configReady").textContent = ready ? "ready" : "waiting for VPS";
      document.getElementById("configReady").className = `value ${ready ? "ok" : "warn"}`;
      document.getElementById("configReadyHint").textContent = ready
        ? "This router already has an active client profile and can bring the path up when the switch is ON."
        : "The router platform is installed, but no client profile has been applied yet.";

      const pathEl = document.getElementById("pathActive");
      const pathHint = document.getElementById("pathActiveHint");
      if (!ready) {
        pathEl.textContent = "waiting for VPS profile";
        pathEl.className = "value warn";
        pathHint.textContent = "Nothing is broken: the platform is installed, but the router still needs one successful VPS sync.";
      } else if (data.path_state === "switch_off") {
        pathEl.textContent = "idle";
        pathEl.className = "value warn";
        pathHint.textContent = "The client profile is ready, but the physical switch is OFF, so the path stays down on purpose.";
      } else if (data.path_state === "failsafe") {
        pathEl.textContent = "blocked";
        pathEl.className = "value bad";
        pathHint.textContent = `Client internet is blocked to prevent direct bypass while Xray is unavailable. ${data.failsafe_reason || data.failsafe_hold_reason || "Use Recover Xray Path after fixing the cause."}`;
      } else if (data.path_state === "degraded") {
        pathEl.textContent = "degraded";
        pathEl.className = "value bad";
        pathHint.textContent = "The local runtime is up, but the latest smoke failed. Selected Xray traffic is likely broken until the VPS path recovers.";
      } else {
        applyState(pathEl, data.path_active, "active", "inactive");
        pathHint.textContent = data.path_active
          ? "The live transparent path is active right now."
          : "The router has a client profile, but the path is not active yet. Check the switch position, runtime state and VPS health.";
      }

      const smokeOutput = document.getElementById("smokeOutput");
      if (smokeOutput && data.last_smoke_status) {
        smokeOutput.textContent = [
          `Last smoke: ${data.last_smoke_status}${data.last_smoke_at ? ` at ${formatUnixTime(data.last_smoke_at)}` : ""}`,
          `HTTPS probe: ${data.last_smoke_https_ok ? "ok" : "failed"}`,
          `Egress probe: ${data.last_smoke_egress_ok ? "ok" : "failed"}`,
          `OpenAI probe: ${data.last_smoke_openai_ok ? "ok" : "failed"}`,
          `Fail-safe: ${data.failsafe_active ? "active" : "inactive"}${data.failsafe_reason ? ` (${data.failsafe_reason})` : ""}`,
          data.failsafe_hold_active ? `Recovery hold until: ${formatUnixTime(data.failsafe_hold_until)}` : "",
          "",
          data.last_smoke_message || "(no summary saved yet)"
        ].join("\n");
      }

      document.getElementById("setupNotice").style.display = ready ? "none" : "block";
    }

    function renderHeroAndSummary(profile) {
      const runtime = state.runtime || {};
      const remote = profile?.remote_cache || {};
      const routerDiff = parseDiffList(profile?.router_diff || "");
      const remoteDiff = parseDiffList(profile?.remote_diff || "");
      const drift = routerDiff.length || remoteDiff.length;
      document.getElementById("heroProfile").textContent = profile?.label || profile?.id || "...";
      document.getElementById("heroTarget").textContent = runtime.config_ready
        ? (runtime.server_address || profile?.endpoint_host || "...")
        : (profile?.endpoint_host || "No active VPS yet");

      document.getElementById("summaryRemoteIp").textContent = remote.public_ip || "(unknown)";
      const inspectStatus = remote.status || profile?.last_inspect_status || "never";
      const inspectText = inspectStatus === "ok"
        ? `ok · ${formatUnixTime(profile?.last_inspect_at)}`
        : inspectStatus;
      document.getElementById("summaryInspect").textContent = inspectText;
      document.getElementById("summaryInspect").className = `value ${inspectStatus === "ok" ? "ok" : "warn"}`;
      // Transport mismatch (DIAGNOSTIC-TREE 8.5 / G8) is more severe than
      // field drift: if the router dials one transport (e.g. raw/reality)
      // while the VPS serves another (ws/tls), the tunnel cannot come up
      // at all, even though identity fields may match. Surface it loudly
      // and above the normal drift text, since identity-diff can read
      // "in sync" while the transport silently disagrees.
      const router = state.vps?.router_current || {};
      const rNet = (router.transport_net || "").toLowerCase();
      const rSec = (router.transport_sec || "").toLowerCase();
      const vNet = (remote.transport_net || "").toLowerCase();
      const vSec = (remote.transport_sec || "").toLowerCase();
      const transportKnown = rNet && rSec && vNet && vSec;
      const transportMismatch = transportKnown && (rNet !== vNet || rSec !== vSec);

      const driftEl = document.getElementById("summaryDrift");
      if (transportMismatch) {
        driftEl.textContent = `transport mismatch: router ${rNet}/${rSec} vs VPS ${vNet}/${vSec}`;
        driftEl.className = "value bad";
        driftEl.title = "The router and VPS use different transports — the tunnel will not connect. Re-run install.sh from one source, or run scripts/revive-router.sh.";
      } else if (!runtime.config_ready) {
        driftEl.textContent = "waiting for first apply";
        driftEl.className = "value warn";
        driftEl.title = "";
      } else {
        driftEl.textContent = drift ? "needs sync" : "in sync";
        driftEl.className = `value ${drift ? "warn" : "ok"}`;
        driftEl.title = "";
      }
    }

