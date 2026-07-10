    // Install banner — polls /cgi-bin/xray-admin?action=install_status which
    // returns the contents of /tmp/vpn-xray-install-status.json (written by
    // common/lib/install-progress.sh during a deploy). Poll runs forever; a
    // missing or empty status file resolves to state=idle and hides the
    // banner. Failed state stays visible until the operator re-runs the
    // install successfully.
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
        banner.classList.add("complete");
        titleEl.textContent = "Install complete";
        bodyEl.textContent = `${stepTotal}/${stepTotal} steps OK`;
        fixEl.hidden = true;
        // Auto-hide success banners after 8 seconds — failures persist.
        setTimeout(() => {
          if (!banner.classList.contains("running")) {
            banner.hidden = true;
          }
        }, 8000);
      }
    }
    refreshInstallBanner();
    setInterval(refreshInstallBanner, 5000);
