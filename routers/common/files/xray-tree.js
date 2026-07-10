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
    var el = document.getElementById("pathHealthTree");
    if (el) el.innerHTML = nodes.map(rowHtml).join("");
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

  // One delegated click handler for all (current and future) repair buttons.
  document.addEventListener("click", function (ev) {
    var btn = ev.target && ev.target.closest && ev.target.closest(".tree-repair-btn");
    if (btn) onRepairClick(btn);
  });

  renderPathHealth();
  setInterval(renderPathHealth, 5000);
})();
