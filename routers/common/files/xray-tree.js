// Path Health — renders the unified diagnostic tree (xray-admin?action=tree)
// as a live decision tree. Each manifest node becomes a row with a status
// glyph, id, title, status label, detail, and badges (self-heal / open gap).
// Read-only for now (design phase 3); the per-node repair affordance and the
// tree-walking Diagnose & Repair are phase 4. See
// docs/UNIFIED-DIAGNOSTIC-UI-DESIGN.md.
(function () {
  "use strict";
  var GLYPH = { ok: "●", degraded: "◐", failed: "✗", unknown: "○", na: "⚠" };

  function esc(s) {
    return String(s == null ? "" : s)
      .replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;");
  }

  function rowHtml(n) {
    var status = n.status || "unknown";
    var indent = n.parent ? 1 : 0;
    var badges = "";
    if (n.auto && n.auto !== "none") {
      badges += '<span class="tree-badge auto" title="self-heals unattended: ' + esc(n.auto) + '">self-heal</span>';
    }
    if (n.gap) {
      badges += '<span class="tree-badge gap" title="open gap ' + esc(n.gap) + ' — diagnose-only, no automatic repair yet">' + esc(n.gap) + "</span>";
    }
    // A broken node that has a one-click router-side repair gets an inline
    // button. risk="disruptive" repairs restart the path, so the click is
    // confirmed first (see onRepairClick).
    var action = "";
    if (n.can_repair && (status === "failed" || status === "degraded")) {
      action = '<button class="tree-repair-btn" data-node="' + esc(n.id) + '" data-risk="' + esc(n.risk || "") +
        '" data-title="' + esc(n.title) + '" type="button">Repair</button>';
    }
    return '<div class="tree-row status-' + esc(status) + '" style="padding-left:' + (indent * 22 + 8) + 'px">' +
      '<span class="tree-glyph">' + (GLYPH[status] || GLYPH.unknown) + "</span>" +
      '<span class="tree-id">' + esc(n.id) + "</span>" +
      '<span class="tree-title">' + esc(n.title) + "</span>" +
      '<span class="tree-status-label">' + esc(status) + "</span>" +
      '<span class="tree-detail">' + esc(n.detail) + "</span>" +
      badges +
      action +
      "</div>";
  }

  function paint(nodes) {
    // Overlay the config-coherence nodes (8 / 8.5) with the signals the main
    // app derives from the VPS data it already polls (window.__diagVpsStatus),
    // so those rows are live instead of "see VPS panel". Router-side nodes are
    // untouched — the tree endpoint owns them.
    var o = window.__diagVpsStatus || {};
    var merged = nodes.map(function (n) {
      if (o[n.id]) {
        var m = {};
        for (var k in n) m[k] = n[k];
        m.status = o[n.id];
        if (o[n.id + "_detail"]) m.detail = o[n.id + "_detail"];
        return m;
      }
      return n;
    });
    var el = document.getElementById("pathHealthTree");
    if (el) el.innerHTML = merged.map(rowHtml).join("");
  }

  var repairBusy = false;
  async function onRepairClick(btn) {
    if (repairBusy) return;
    var id = btn.getAttribute("data-node");
    var title = btn.getAttribute("data-title") || ("node " + id);
    if (!window.confirm('Repair "' + title + '"?\nThis restarts the transparent proxy path and briefly interrupts client traffic.')) {
      return;
    }
    repairBusy = true;
    btn.disabled = true;
    btn.textContent = "Repairing…";
    try {
      var resp = await fetch("/cgi-bin/xray-admin", {
        method: "POST",
        headers: { "Content-Type": "application/x-www-form-urlencoded" },
        body: "action=node_repair&node=" + encodeURIComponent(id),
      });
      var data = await resp.json();
      if (data && data.tree && Array.isArray(data.tree.nodes)) paint(data.tree.nodes);
      var flash = document.getElementById("flash");
      if (flash) {
        flash.textContent = (data && data.message) || "Repair finished.";
        flash.className = "flash " + (data && data.ok ? "ok" : "err");
        setTimeout(function () { flash.textContent = ""; flash.className = "flash"; }, 6000);
      }
    } catch (_err) {
      /* leave the tree as-is; next poll refreshes it */
    } finally {
      repairBusy = false;
    }
  }

  async function renderPathHealth() {
    var el = document.getElementById("pathHealthTree");
    if (!el) return;
    var data;
    try {
      var resp = await fetch("/cgi-bin/xray-admin?action=tree", { cache: "no-store" });
      data = await resp.json();
    } catch (_err) {
      // Transient CGI/network blip — keep the last rendered tree.
      return;
    }
    if (!data || !Array.isArray(data.nodes)) return;
    if (repairBusy) return; // don't clobber a repair-in-progress row
    paint(data.nodes);
  }

  function flashMsg(text, ok, ms) {
    var flash = document.getElementById("flash");
    if (!flash) return;
    flash.textContent = text;
    flash.className = "flash " + (ok ? "ok" : "err");
    setTimeout(function () { flash.textContent = ""; flash.className = "flash"; }, ms || 8000);
  }

  // The single, whole-path Diagnose & Repair. Walks the tree bottom-up: first
  // the router-side layers (tree_repair restarts runtime / redsocks / transport),
  // then — only if the path is still down — it escalates to the VPS server repair
  // by triggering the existing VPS flow (its creds prompt / progress / report),
  // which owns node 6 and config apply. One button for the whole tree.
  async function onWalkClick(btn) {
    if (repairBusy) return;
    if (!window.confirm("Diagnose & Repair the whole path?\nThis restarts the broken router-side layers (runtime / redsocks / transport). If the path is still down because of the VPS server or config, it then runs the VPS repair (which may ask for the VPS password). Client traffic is briefly interrupted.")) {
      return;
    }
    repairBusy = true;
    btn.disabled = true;
    var label = btn.textContent;
    btn.textContent = "Repairing path…";
    try {
      var resp = await fetch("/cgi-bin/xray-admin", {
        method: "POST",
        headers: { "Content-Type": "application/x-www-form-urlencoded" },
        body: "action=tree_repair",
      });
      var data = await resp.json();
      if (data && data.tree && Array.isArray(data.tree.nodes)) paint(data.tree.nodes);
      if (data && data.ok) {
        // Router walk fixed it (or nothing router-side was broken and the path
        // is healthy). Done — no need to touch the VPS.
        flashMsg((data && data.message) || "Path is healthy.", true);
      } else {
        // Path still down after the router layers — the cause is the VPS server
        // or config. Escalate to the VPS repair, reusing its full flow.
        var vpsBtn = document.getElementById("diagnoseRepairBtn");
        if (vpsBtn && !vpsBtn.disabled) {
          flashMsg((data && data.message ? data.message + " " : "") + "Running VPS repair…", false, 6000);
          repairBusy = false; // hand off to the VPS flow (it manages its own busy/progress)
          btn.disabled = false;
          btn.textContent = label;
          vpsBtn.click();
          return;
        }
        flashMsg((data && data.message) || "Path still down; run the VPS repair.", false);
      }
    } catch (_err) {
      /* next poll refreshes the tree */
    } finally {
      if (repairBusy) {
        repairBusy = false;
        btn.disabled = false;
        btn.textContent = label;
      }
    }
  }

  // One delegated click handler for the per-node repair buttons and the
  // whole-path walk button.
  document.addEventListener("click", function (ev) {
    if (!ev.target || !ev.target.closest) return;
    var rbtn = ev.target.closest(".tree-repair-btn");
    if (rbtn) { onRepairClick(rbtn); return; }
    var wbtn = ev.target.closest("#pathHealthWalkBtn");
    if (wbtn) onWalkClick(wbtn);
  });

  renderPathHealth();
  setInterval(renderPathHealth, 5000);
})();
