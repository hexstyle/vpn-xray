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
    return '<div class="tree-row status-' + esc(status) + '" style="padding-left:' + (indent * 22 + 8) + 'px">' +
      '<span class="tree-glyph">' + (GLYPH[status] || GLYPH.unknown) + "</span>" +
      '<span class="tree-id">' + esc(n.id) + "</span>" +
      '<span class="tree-title">' + esc(n.title) + "</span>" +
      '<span class="tree-status-label">' + esc(status) + "</span>" +
      '<span class="tree-detail">' + esc(n.detail) + "</span>" +
      badges +
      "</div>";
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
    el.innerHTML = data.nodes.map(rowHtml).join("");
  }

  renderPathHealth();
  setInterval(renderPathHealth, 5000);
})();
