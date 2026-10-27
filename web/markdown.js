// Minimal, safe Markdown renderer for LLM summaries (headings, lists, bold/italic/code, links).
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

  function renderMarkdown(src) {
    const lines = String(src || "").replace(/\r\n/g, "\n").split("\n");
    const out = [];
    const stack = []; // open lists: {type, indent}
    let para = [];

    const flushPara = () => {
      if (para.length) out.push("<p>" + inline(para.join(" ")) + "</p>");
      para = [];
    };
    const closeLists = (toIndent) => {
      while (stack.length && stack[stack.length - 1].indent >= toIndent) {
        out.push("</li></" + stack.pop().type + ">");
      }
    };

    for (const raw of lines) {
      const line = raw.replace(/\s+$/, "");
      if (!line.trim()) { flushPara(); closeLists(0); continue; }

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
    return out.join("");
  }

  root.renderMarkdown = renderMarkdown;
  root.escapeHtml = esc;
  if (typeof module !== "undefined") module.exports = { renderMarkdown, escapeHtml: esc };
})(typeof window !== "undefined" ? window : globalThis);
