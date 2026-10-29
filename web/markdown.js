// Minimal, safe Markdown renderer for LLM summaries (headings, lists, bold/italic/code, links,
// fenced code, tables). ```mermaid blocks become <div class="diagram"> placeholders that app.js
// draws with Pele; until a block is closed (while streaming) it shows as code.
(function (root) {
  function esc(s) {
    return String(s).replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));
  }

  function inline(text) {
    let s = esc(text);
    s = s.replace(/`([^`]+)`/g, "<code>$1</code>");
    s = s.replace(/\*\*([^*]+)\*\*/g, "<strong>$1</strong>");
    s = s.replace(/(^|[\s(])\*([^*\s][^*]*)\*(?=$|[\s).,;:])/g, "$1<em>$2</em>");
    s = s.replace(/\[([^\]]+)\]\((https?:\/\/[^)\s]+)\)/g, '<a href="$2">$1</a>');
    return s;
  }

  const cells = (row) => row.trim().replace(/^\|/, "").replace(/\|$/, "").split("|").map((c) => c.trim());
  const isDivider = (row) => /^\s*\|?\s*:?-{2,}:?\s*(\|\s*:?-{2,}:?\s*)*\|?\s*$/.test(row || "");

  function renderMarkdown(src) {
    const lines = String(src || "").replace(/\r\n/g, "\n").split("\n");
    const out = [];
    const stack = []; // open lists: {type, indent}
    let para = [];
    let fence = null; // {lang, body: []}

    const flushPara = () => {
      if (para.length) out.push("<p>" + inline(para.join(" ")) + "</p>");
      para = [];
    };
    const closeLists = (toIndent) => {
      while (stack.length && stack[stack.length - 1].indent >= toIndent) {
        out.push("</li></" + stack.pop().type + ">");
      }
    };

    const codeBlock = (f, closed) => {
      const body = f.body.join("\n");
      if (closed && f.lang === "mermaid") {
        return `<div class="diagram"><pre class="diagram-src">${esc(body)}</pre></div>`;
      }
      return `<pre class="code"><code>${esc(body)}</code></pre>`;
    };

    for (let i = 0; i < lines.length; i++) {
      const raw = lines[i];
      if (fence) {
        if (/^\s*```\s*$/.test(raw)) { out.push(codeBlock(fence, true)); fence = null; }
        else fence.body.push(raw);
        continue;
      }
      const line = raw.replace(/\s+$/, "");
      const open = /^\s*```\s*([\w-]*)/.exec(line);
      if (open) { flushPara(); closeLists(0); fence = { lang: open[1].toLowerCase(), body: [] }; continue; }
      if (!line.trim()) { flushPara(); closeLists(0); continue; }

      if (/^\s*\|/.test(line) && isDivider(lines[i + 1])) {
        flushPara(); closeLists(0);
        const head = cells(line);
        let html = "<div class=\"table-wrap\"><table><thead><tr>" + head.map((c) => `<th>${inline(c)}</th>`).join("") + "</tr></thead><tbody>";
        i += 1;
        while (i + 1 < lines.length && /^\s*\|/.test(lines[i + 1])) {
          const row = cells(lines[++i]);
          html += "<tr>" + head.map((_, j) => `<td>${inline(row[j] || "")}</td>`).join("") + "</tr>";
        }
        out.push(html + "</tbody></table></div>");
        continue;
      }

      const h = /^(#{1,3})\s+(.*)$/.exec(line);
      if (h) {
        flushPara(); closeLists(0);
        out.push(`<h${h[1].length}>${inline(h[2])}</h${h[1].length}>`);
        continue;
      }

      const li = /^(\s*)([-*•]|\d+[.)])\s+(.*)$/.exec(line);
      if (li) {
        flushPara();
        const indent = li[1].length;
        const type = /\d/.test(li[2]) ? "ol" : "ul";
        const top = stack[stack.length - 1];
        if (!top || indent > top.indent) {
          out.push("<" + type + "><li>");
          stack.push({ type, indent });
        } else {
          closeLists(indent + 1);
          const cur = stack[stack.length - 1];
          if (cur && cur.indent === indent) out.push("</li><li>");
          else { out.push("<" + type + "><li>"); stack.push({ type, indent }); }
        }
        out.push(inline(li[3]));
        continue;
      }

      if (stack.length && /^\s+/.test(line)) { out.push(" " + inline(line.trim())); continue; } // list continuation
      closeLists(0);
      para.push(line.trim());
    }
    flushPara(); closeLists(0);
    if (fence) out.push(codeBlock(fence, false));
    return out.join("");
  }

  root.renderMarkdown = renderMarkdown;
  root.escapeHtml = esc;
  if (typeof module !== "undefined") module.exports = { renderMarkdown, escapeHtml: esc };
})(typeof window !== "undefined" ? window : globalThis);
