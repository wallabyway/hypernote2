/* Hypernote2 web UI. Talks to Swift through window.webkit.messageHandlers.native. */
(function () {
  "use strict";
  const esc = window.escapeHtml;
  const $ = (sel, root = document) => root.querySelector(sel);

  // ---------- native bridge ----------
  function native(cmd, args = {}) {
    const handler = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.native;
    if (!handler) return Promise.reject("Not running inside Hypernote2.app");
    return handler.postMessage({ cmd, args });
  }
  window.native = native;

  // ---------- state ----------
  const S = {
    boot: null,            // {hasAssemblyKey, hasDeepseekKey, settings, templates, recordingSessionId}
    sessions: [],
    cur: null,             // full current session
    tab: "summary",
    view: "loading",       // loading | setup | note | settings
    search: "",
    rec: { id: null, seconds: 0, level: 0 },
    confirmDelete: null,
    editingSpeaker: null,
    editTemplate: null,
    titleDirty: false,
  };

  const SPEAKER_COLORS = ["#2563eb", "#dc2626", "#16a34a", "#9333ea", "#ea580c", "#0891b2", "#db2777", "#65a30d"];
  const STATUS_TEXT = {
    uploading: "Uploading audio…",
    transcribing: "Transcribing and labelling speakers…",
    summarizing: "Writing summary…",
  };

  const ICONS = {
    plus: '<path d="M12 5v14M5 12h14"/>',
    search: '<circle cx="11" cy="11" r="7"/><path d="m21 21-4.3-4.3"/>',
    gear: '<circle cx="12" cy="12" r="3"/><path d="M19.4 15a1.7 1.7 0 0 0 .3 1.8l.1.1a2 2 0 1 1-2.8 2.8l-.1-.1a1.7 1.7 0 0 0-1.8-.3 1.7 1.7 0 0 0-1 1.5V21a2 2 0 1 1-4 0v-.1a1.7 1.7 0 0 0-1.1-1.5 1.7 1.7 0 0 0-1.8.3l-.1.1a2 2 0 1 1-2.8-2.8l.1-.1a1.7 1.7 0 0 0 .3-1.8 1.7 1.7 0 0 0-1.5-1H3a2 2 0 1 1 0-4h.1a1.7 1.7 0 0 0 1.5-1.1 1.7 1.7 0 0 0-.3-1.8l-.1-.1a2 2 0 1 1 2.8-2.8l.1.1a1.7 1.7 0 0 0 1.8.3H9a1.7 1.7 0 0 0 1-1.5V3a2 2 0 1 1 4 0v.1a1.7 1.7 0 0 0 1 1.5 1.7 1.7 0 0 0 1.8-.3l.1-.1a2 2 0 1 1 2.8 2.8l-.1.1a1.7 1.7 0 0 0-.3 1.8V9a1.7 1.7 0 0 0 1.5 1H21a2 2 0 1 1 0 4h-.1a1.7 1.7 0 0 0-1.5 1z"/>',
    copy: '<rect x="9" y="9" width="13" height="13" rx="2"/><path d="M5 15H4a2 2 0 0 1-2-2V4a2 2 0 0 1 2-2h9a2 2 0 0 1 2 2v1"/>',
    refresh: '<path d="M21 12a9 9 0 1 1-3-6.7L21 8"/><path d="M21 3v5h-5"/>',
    sparkles: '<path d="m12 3 1.9 5.1L19 10l-5.1 1.9L12 17l-1.9-5.1L5 10l5.1-1.9z"/><path d="M19 3v4M17 5h4"/>',
    folder: '<path d="M3 7a2 2 0 0 1 2-2h4l2 2h8a2 2 0 0 1 2 2v8a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2z"/>',
  };
  const icon = (n) => `<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">${ICONS[n]}</svg>`;

  // ---------- helpers ----------
  const fmtClock = (s) => {
    s = Math.max(0, Math.floor(s));
    const h = Math.floor(s / 3600), m = Math.floor((s % 3600) / 60), sec = s % 60;
    const mm = String(m).padStart(2, "0"), ss = String(sec).padStart(2, "0");
    return h ? `${h}:${mm}:${ss}` : `${mm}:${ss}`;
  };
  const fmtMs = (ms) => fmtClock(ms / 1000);
  const fmtDur = (s) => (s < 60 ? `${Math.round(s)}s` : `${Math.round(s / 60)} min`);
  const timeOf = (iso) => new Date(iso).toLocaleTimeString([], { hour: "numeric", minute: "2-digit" });
  const dateLong = (iso) => new Date(iso).toLocaleDateString([], { weekday: "short", month: "short", day: "numeric", year: "numeric" });

  function groupLabel(iso) {
    const d = new Date(iso), now = new Date();
    const day = (x) => new Date(x.getFullYear(), x.getMonth(), x.getDate()).getTime();
    const diff = Math.round((day(now) - day(d)) / 86400000);
    if (diff <= 0) return "Today";
    if (diff === 1) return "Yesterday";
    if (diff < 7) return "This week";
    return d.toLocaleDateString([], { month: "long", year: "numeric" });
  }

  function toast(message, kind = "info", ms = 6000) {
    const el = document.createElement("div");
    el.className = "toast " + kind;
    el.textContent = message;
    $("#toasts").appendChild(el);
    setTimeout(() => el.remove(), ms);
  }
  const fail = (e) => toast(String(e && e.message ? e.message : e), "error");

  const templateById = (id) => (S.boot.templates.find((t) => t.id === id) || S.boot.templates[0]);
  const isBusy = (s) => ["uploading", "transcribing", "summarizing"].includes(s.status);
  const speakerName = (s, label) => (s.speakerNames && s.speakerNames[label]) || `Speaker ${label}`;

  // ---------- data ----------
  async function refreshList() {
    S.sessions = await native("listSessions");
    renderSidebar();
  }

  async function openSession(id) {
    S.cur = await native("getSession", { id });
    S.view = "note";
    S.titleDirty = false;
    S.editingSpeaker = null;
    S.tab = S.cur.summary || isBusy(S.cur) ? "summary" : S.cur.utterances.length ? "transcript" : "notes";
    if (S.cur.status === "recording") S.tab = "notes";
    if (S.cur.status === "error") S.tab = "summary";
    render();
  }

  async function newNote() {
    const s = await native("createSession");
    await refreshList();
    await openSession(s.id);
    setTimeout(() => { const t = $("#title"); if (t) t.focus(); }, 30);
  }

  let saveTimer = null;
  function queueSave(fields) {
    clearTimeout(saveTimer);
    const id = S.cur.id;
    saveTimer = setTimeout(async () => {
      try {
        await native("updateSession", { id, ...fields });
        if (fields.title !== undefined) { S.titleDirty = false; refreshList(); }
      } catch (e) { fail(e); }
    }, 400);
  }

  // ---------- rendering ----------
  function render() {
    renderSidebar();
    renderMain();
  }

  function shell() {
    if ($("#sidebar")) return;
    $("#app").innerHTML = `<div class="shell"><aside class="sidebar" id="sidebar"></aside><section class="main" id="main"></section></div>`;
    document.addEventListener("mousedown", (e) => {
      if (e.target.classList && e.target.classList.contains("drag")) native("dragWindow").catch(() => {});
    });
  }

  function renderSidebar() {
    const el = $("#sidebar");
    if (!el) return;
    const q = S.search.trim().toLowerCase();
    const items = S.sessions.filter((s) => !q || (s.title + " " + s.snippet).toLowerCase().includes(q));
    let html = `
      <div class="drag"><span class="brand">Hypernote2</span>
        <button class="icon-btn" id="new-btn" title="New note (⌘N)">${icon("plus")}</button></div>
      <div class="search">${icon("search")}<input id="search" placeholder="Search notes" value="${esc(S.search)}" /></div>
      <div class="list">`;
    let last = "";
    for (const s of items) {
      const g = groupLabel(s.createdAt);
      if (g !== last) { html += `<div class="group-title">${esc(g)}</div>`; last = g; }
      const dot = s.status === "recording" ? "rec" : ["uploading", "transcribing", "summarizing"].includes(s.status) ? "busy" : s.status === "error" ? "err" : "";
      const confirming = S.confirmDelete === s.id;
      html += `<div class="item ${S.cur && S.cur.id === s.id && S.view === "note" ? "active" : ""}" data-id="${s.id}">
        <div class="t">${esc(s.title || "Untitled")}</div>
        <div class="s">${dot ? `<span class="dot ${dot}"></span>` : ""}${esc(timeOf(s.createdAt))}${s.snippet ? " · " + esc(s.snippet) : ""}</div>
        <button class="icon-btn del ${confirming ? "confirm" : ""}" data-del="${s.id}">${confirming ? "Delete?" : "✕"}</button></div>`;
    }
    if (!items.length) html += `<div class="empty" style="padding:32px 8px">${q ? "No matches" : "No notes yet"}</div>`;
    html += `</div><div class="sidebar-foot"><span>${S.boot && S.boot.hasAssemblyKey && S.boot.hasDeepseekKey ? "AssemblyAI · DeepSeek" : "Keys not set"}</span>
      <button class="icon-btn" id="settings-btn" title="Settings">${icon("gear")}</button></div>`;
    el.innerHTML = html;

    $("#new-btn").onclick = () => newNote().catch(fail);
    $("#settings-btn").onclick = () => { S.view = "settings"; S.editTemplate = null; render(); };
    const search = $("#search");
    search.oninput = (e) => { S.search = e.target.value; const pos = e.target.selectionStart; renderSidebar(); const n = $("#search"); n.focus(); n.setSelectionRange(pos, pos); };
    el.querySelectorAll(".item").forEach((n) => (n.onclick = (e) => {
      if (e.target.closest(".del")) return;
      openSession(n.dataset.id).catch(fail);
    }));
    el.querySelectorAll(".del").forEach((b) => (b.onclick = async (e) => {
      e.stopPropagation();
      const id = b.dataset.del;
      if (S.confirmDelete !== id) { S.confirmDelete = id; renderSidebar(); return; }
      S.confirmDelete = null;
      try {
        await native("deleteSession", { id });
        if (S.cur && S.cur.id === id) { S.cur = null; S.view = "note"; }
        await refreshList();
        renderMain();
      } catch (err) { fail(err); renderSidebar(); }
    }));
  }

  function renderMain() {
    const el = $("#main");
    if (!el) return;
    const focusId = document.activeElement && document.activeElement.id;
    const sel = document.activeElement && document.activeElement.selectionStart;

    if (S.view === "loading") el.innerHTML = "";
    else if (S.view === "setup") el.innerHTML = setupHTML();
    else if (S.view === "settings") el.innerHTML = settingsHTML();
    else if (!S.cur) el.innerHTML = `<div class="drag"></div><div class="center"><div class="empty"><h3>Welcome to Hypernote2</h3>Record a meeting and get a transcript with speakers, plus a summary in the template you choose.<br><button class="btn primary" id="empty-new">${icon("plus")} New note</button></div></div>`;
    else el.innerHTML = noteHTML();

    bindMain();
    if (focusId) {
      const n = document.getElementById(focusId);
      if (n) { n.focus(); if (sel != null && n.setSelectionRange && n.type !== "password") try { n.setSelectionRange(sel, sel); } catch (_) {} }
    }
  }

  // ----- setup -----
  function setupHTML() {
    return `<div class="drag"></div><div class="center"><div class="card">
      <h1>Set up Hypernote2</h1>
      <p class="sub">Everything runs in the cloud with your own keys — nothing is downloaded to your Mac. Keys are stored in your macOS Keychain.</p>
      <div class="field"><label>AssemblyAI API key</label>
        <input type="password" id="key-aai" autocomplete="off" spellcheck="false" placeholder="Transcription + speaker labels" />
        <div class="help">Get one at <a class="link" data-url="https://www.assemblyai.com/dashboard/api-keys">assemblyai.com/dashboard</a></div></div>
      <div class="field"><label>DeepSeek API key</label>
        <input type="password" id="key-ds" autocomplete="off" spellcheck="false" placeholder="Summaries with DeepSeek Flash" />
        <div class="help">Get one at <a class="link" data-url="https://platform.deepseek.com/api_keys">platform.deepseek.com</a></div></div>
      <button class="btn primary" id="save-keys" style="height:36px;padding:0 18px">Verify and continue</button>
      <div class="help" id="setup-status" style="margin-top:10px"></div>
    </div></div>`;
  }

  // ----- settings -----
  function settingsHTML() {
    const b = S.boot, set = b.settings;
    const tpls = b.templates.map((t) => `
      <div class="tpl"><span class="ic">${esc(t.icon)}</span>
        <div class="grow"><b>${esc(t.title)}</b>${t.builtIn ? ' <span class="chip" style="height:18px;font-size:11px">built-in</span>' : ""}<small>${esc(t.description)}</small></div>
        <button class="btn" data-tpl-dup="${esc(t.id)}">Duplicate</button>
        ${t.builtIn ? "" : `<button class="btn" data-tpl-edit="${esc(t.id)}">Edit</button><button class="btn danger" data-tpl-del="${esc(t.id)}">Delete</button>`}
      </div>`).join("");
    return `<div class="drag"></div><div class="scroll"><div class="settings">
      <h1>Settings</h1>
      <div class="section"><h2>API keys</h2>
        <div class="field"><label>AssemblyAI ${b.hasAssemblyKey ? '<span class="ok">✓ saved</span>' : ""}</label>
          <input type="password" id="key-aai" autocomplete="off" spellcheck="false" placeholder="${b.hasAssemblyKey ? "Enter a new key to replace" : "Paste key"}" /></div>
        <div class="field"><label>DeepSeek ${b.hasDeepseekKey ? '<span class="ok">✓ saved</span>' : ""}</label>
          <input type="password" id="key-ds" autocomplete="off" spellcheck="false" placeholder="${b.hasDeepseekKey ? "Enter a new key to replace" : "Paste key"}" />
          <div class="help">Model: ${esc(set.deepseekModel)}</div></div>
        <button class="btn primary" id="save-keys">Verify and save</button>
        <div class="help" id="setup-status" style="margin-top:8px"></div></div>
      <div class="section"><h2>Recording</h2>
        <div class="row"><div><b>Capture other participants</b><div class="help">Also records system audio (Zoom, Meet, Teams…). Needs Screen &amp; System Audio Recording permission.</div></div>
          <button class="switch ${set.captureSystemAudio ? "on" : ""}" id="sys-toggle" aria-label="Capture system audio"></button></div>
        <div class="field" style="margin-top:14px"><label>Default template</label>
          <select id="default-tpl">${b.templates.map((t) => `<option value="${esc(t.id)}" ${t.id === set.defaultTemplateId ? "selected" : ""}>${esc(t.icon)} ${esc(t.title)}</option>`).join("")}</select></div></div>
      <div class="section"><h2>Summary templates</h2>${S.editTemplate ? templateEditorHTML() : tpls + `<div style="margin-top:12px"><button class="btn" id="tpl-new">${icon("plus")} New template</button></div>`}</div>
      <div class="help">Notes and audio are stored in ~/Library/Application Support/Hypernote2. Audio is uploaded to AssemblyAI for transcription; transcripts are sent to DeepSeek for summaries.</div>
    </div></div>`;
  }

  function templateEditorHTML() {
    const t = S.editTemplate;
    return `<div class="field"><label>Name</label><input class="plain" type="text" id="te-title" value="${esc(t.title)}" /></div>
      <div class="field"><label>Icon (emoji)</label><input class="plain" type="text" id="te-icon" value="${esc(t.icon)}" style="width:80px" /></div>
      <div class="field"><label>Description</label><input class="plain" type="text" id="te-desc" value="${esc(t.description)}" /></div>
      <div class="field"><label>Sections</label>
        ${t.sections.map((s, i) => `<div class="sec-edit"><input class="plain" type="text" data-sec-title="${i}" placeholder="Heading" value="${esc(s.title)}" />
          <input class="plain" type="text" data-sec-desc="${i}" placeholder="What should go here?" value="${esc(s.description)}" />
          <button class="btn danger" data-sec-del="${i}">✕</button></div>`).join("")}
        <button class="btn" id="te-add">${icon("plus")} Add section</button></div>
      <div class="row" style="justify-content:flex-start"><button class="btn primary" id="te-save">Save template</button><button class="btn" id="te-cancel">Cancel</button></div>`;
  }

  // ----- note -----
  function noteHTML() {
    const s = S.cur;
    const recordingThis = S.rec.id === s.id;
    const tplOptions = S.boot.templates.map((t) => `<option value="${esc(t.id)}" ${t.id === s.templateId ? "selected" : ""}>${esc(t.icon)} ${esc(t.title)}</option>`).join("");
    const meta = [dateLong(s.createdAt)];
    if (s.durationSec) meta.push(fmtDur(s.durationSec));
    return `<div class="drag"></div>
      <div class="scroll"><div class="note">
        <input id="title" class="title-input" placeholder="Untitled" value="${esc(s.title)}" />
        <div class="meta"><span>${esc(meta.join(" · "))}</span>
          <select class="chip" id="tpl-select" title="Summary template">${tplOptions}</select>
          ${s.hasAudio ? `<a class="link" id="reveal">Show audio</a>` : ""}</div>
        <div class="tabs">
          ${["notes", "summary", "transcript"].map((t) => `<button class="tab ${S.tab === t ? "active" : ""}" data-tab="${t}">${{ notes: "Notes", summary: "Summary", transcript: "Transcript" }[t]}</button>`).join("")}
        </div>
        <div id="tab-body">${tabBodyHTML()}</div>
      </div></div>
      ${listenHTML(recordingThis)}`;
  }

  function listenHTML(recordingThis) {
    const s = S.cur;
    if (recordingThis) {
      return `<button class="listen live" id="stop-btn"><span class="stop"></span>Stop <span class="bars" id="bars">${"<i></i>".repeat(5)}</span><span class="time" id="rec-time">${fmtClock(S.rec.seconds)}</span></button>`;
    }
    if (s.hasAudio || isBusy(s)) return "";
    if (S.rec.id) return `<button class="listen" disabled><span class="rec-dot"></span>Recording in another note</button>`;
    return `<button class="listen" id="start-btn"><span class="rec-dot"></span>Start recording</button>`;
  }

  function tabBodyHTML() {
    const s = S.cur;
    if (S.tab === "notes") {
      return `<textarea id="notes" class="notes-area" placeholder="Jot notes while you listen. Hypernote2 uses them to decide what matters in the summary.">${esc(s.notes)}</textarea>`;
    }
    if (S.tab === "transcript") return transcriptHTML();
    return summaryHTML();
  }

  function summaryHTML() {
    const s = S.cur;
    let html = "";
    if (s.status === "error") {
      html += `<div class="error-card"><b>Something went wrong</b><div class="selectable">${esc(s.error || "Unknown error")}</div>
        <button class="btn" id="retry-btn">${icon("refresh")} Try again</button></div>`;
    }
    if (s.status === "uploading" || s.status === "transcribing") {
      return html + `<div class="progress"><span class="spinner"></span><div><b>${STATUS_TEXT[s.status]}</b><div class="help">Long meetings can take a few minutes. You can leave this note.</div></div></div>`;
    }
    if (s.status === "recording") {
      return html + `<div class="empty"><h3>Recording…</h3>Take notes in the Notes tab. Press Stop when the meeting ends and Hypernote2 will transcribe and summarize it.</div>`;
    }
    const canGenerate = s.utterances.length || s.notes.trim();
    const hasText = s.summary && s.summary.trim();
    if (!hasText && s.status !== "summarizing") {
      return html + `<div class="empty"><h3>No summary yet</h3>${canGenerate ? "Choose a template above and generate a summary." : "Record a meeting or type some notes first."}
        ${canGenerate ? `<br><button class="btn primary" id="gen-btn">${icon("sparkles")} Generate summary</button>` : ""}</div>`;
    }
    return html + `<div class="toolbar"><span class="grow"></span>
        <button class="btn" id="regen-btn" ${s.status === "summarizing" ? "disabled" : ""}>${icon("refresh")} Regenerate</button>
        <button class="btn" id="copy-summary">${icon("copy")} Copy</button></div>
      <div class="md selectable ${s.status === "summarizing" ? "caret" : ""}" id="summary-body">${window.renderMarkdown(s.summary)}</div>`;
  }

  function transcriptHTML() {
    const s = S.cur;
    if (s.status === "uploading" || s.status === "transcribing") {
      return `<div class="progress"><span class="spinner"></span><div><b>${STATUS_TEXT[s.status]}</b></div></div>`;
    }
    if (!s.utterances.length) {
      return `<div class="empty"><h3>No transcript</h3>${s.hasAudio ? "The recording hasn't produced a transcript yet." : "Record a meeting to get a transcript with speaker labels."}
        ${s.hasAudio && s.status !== "recording" ? `<br><button class="btn" id="retry-btn">${icon("refresh")} Transcribe again</button>` : ""}</div>`;
    }
    const rows = s.utterances.map((u) => {
      const color = SPEAKER_COLORS[(u.speaker.charCodeAt(0) - 65 + SPEAKER_COLORS.length * 4) % SPEAKER_COLORS.length];
      const editing = S.editingSpeaker === u.speaker;
      return `<div class="utt"><div class="spk" data-spk="${esc(u.speaker)}"><span class="sw" style="background:${color}"></span>
        <span style="min-width:0">${editing ? `<input id="spk-input" value="${esc(speakerName(s, u.speaker))}" />` : `<span>${esc(speakerName(s, u.speaker))}</span>`}<span class="ts">${fmtMs(u.startMs)}</span></span></div>
        <div class="utt-text">${esc(u.text)}</div></div>`;
    }).join("");
    return `<div class="toolbar"><span class="hint grow">Click a speaker name to rename it everywhere.</span>
      <button class="btn" id="copy-transcript">${icon("copy")} Copy</button></div>${rows}`;
  }

  // ---------- bindings ----------
  function bindMain() {
    const on = (sel, fn) => { const n = $(sel); if (n) n.onclick = fn; };
    document.querySelectorAll("[data-url]").forEach((a) => (a.onclick = () => native("openURL", { url: a.dataset.url })));
    on("#empty-new", () => newNote().catch(fail));

    on("#save-keys", saveKeys);
    on("#sys-toggle", async () => {
      try { S.boot = await native("setSettings", { captureSystemAudio: !S.boot.settings.captureSystemAudio }); renderMain(); } catch (e) { fail(e); }
    });
    const dt = $("#default-tpl");
    if (dt) dt.onchange = async () => { try { S.boot = await native("setSettings", { defaultTemplateId: dt.value }); } catch (e) { fail(e); } };
    bindTemplates();

    if (S.view !== "note" || !S.cur) return;
    const s = S.cur;
    const title = $("#title");
    if (title) title.oninput = () => { s.title = title.value; S.titleDirty = true; queueSave({ title: title.value }); };
    const notes = $("#notes");
    if (notes) notes.oninput = () => { s.notes = notes.value; queueSave({ notes: notes.value }); };
    document.querySelectorAll(".tab").forEach((t) => (t.onclick = () => { S.tab = t.dataset.tab; renderMain(); }));
    const sel = $("#tpl-select");
    if (sel) sel.onchange = async () => {
      s.templateId = sel.value;
      try { await native("updateSession", { id: s.id, templateId: sel.value }); } catch (e) { fail(e); }
    };
    on("#reveal", () => native("revealAudio", { id: s.id }));
    on("#start-btn", async () => {
      try { S.boot = await native("startRecording", { id: s.id }); S.rec = { id: s.id, seconds: 0, level: 0 }; S.tab = "notes"; await refreshCur(); } catch (e) { fail(e); }
    });
    on("#stop-btn", async () => {
      try { await native("stopRecording"); S.rec = { id: null, seconds: 0, level: 0 }; S.boot.recordingSessionId = null; S.tab = "summary"; await refreshCur(); } catch (e) { fail(e); }
    });
    const summarize = async () => { try { await native("summarize", { id: s.id, templateId: s.templateId }); S.tab = "summary"; } catch (e) { fail(e); } };
    on("#gen-btn", summarize);
    on("#regen-btn", summarize);
    on("#retry-btn", async () => { try { await native("retry", { id: s.id }); } catch (e) { fail(e); } });
    on("#copy-summary", () => native("copy", { text: (s.title ? `# ${s.title}\n\n` : "") + s.summary }).then(() => toast("Summary copied")));
    on("#copy-transcript", () => native("copy", { text: s.utterances.map((u) => `[${fmtMs(u.startMs)}] ${speakerName(s, u.speaker)}: ${u.text}`).join("\n") }).then(() => toast("Transcript copied")));

    document.querySelectorAll(".spk").forEach((n) => (n.onclick = (e) => {
      if (e.target.tagName === "INPUT") return;
      S.editingSpeaker = n.dataset.spk; renderMain();
      const i = $("#spk-input"); if (i) { i.focus(); i.select(); }
    }));
    const si = $("#spk-input");
    if (si) {
      const commit = async () => {
        const label = S.editingSpeaker; S.editingSpeaker = null;
        const names = { ...(s.speakerNames || {}) };
        const v = si.value.trim();
        if (v && v !== `Speaker ${label}`) names[label] = v; else delete names[label];
        s.speakerNames = names;
        try { await native("updateSession", { id: s.id, speakerNames: names }); } catch (e) { fail(e); }
        renderMain();
      };
      si.onkeydown = (e) => { if (e.key === "Enter") commit(); if (e.key === "Escape") { S.editingSpeaker = null; renderMain(); } };
      si.onblur = commit;
    }
  }

  async function saveKeys() {
    const aai = ($("#key-aai") || {}).value || "", ds = ($("#key-ds") || {}).value || "";
    const status = $("#setup-status"), btn = $("#save-keys");
    const needAai = !S.boot.hasAssemblyKey && !aai.trim(), needDs = !S.boot.hasDeepseekKey && !ds.trim();
    if (needAai || needDs) { status.textContent = "Both keys are required."; return; }
    btn.disabled = true; status.textContent = "Verifying keys…";
    try {
      S.boot = await native("saveKeys", { assemblyai: aai, deepseek: ds });
      status.innerHTML = '<span class="ok">Keys verified and saved.</span>';
      if (S.view === "setup") { S.view = "note"; await refreshList(); render(); if (!S.cur) await newNote(); }
      else renderMain();
    } catch (e) { status.textContent = String(e); btn.disabled = false; }
  }

  function bindTemplates() {
    const on = (sel, fn) => { const n = $(sel); if (n) n.onclick = fn; };
    on("#tpl-new", () => { S.editTemplate = { id: "", title: "", description: "", icon: "📋", sections: [{ title: "", description: "" }] }; renderMain(); });
    document.querySelectorAll("[data-tpl-dup]").forEach((b) => (b.onclick = () => {
      const t = templateById(b.dataset.tplDup);
      S.editTemplate = { id: "", title: t.title + " (copy)", description: t.description, icon: t.icon, sections: t.sections.map((x) => ({ ...x })) };
      renderMain();
    }));
    document.querySelectorAll("[data-tpl-edit]").forEach((b) => (b.onclick = () => {
      const t = templateById(b.dataset.tplEdit);
      S.editTemplate = { id: t.id, title: t.title, description: t.description, icon: t.icon, sections: t.sections.map((x) => ({ ...x })) };
      renderMain();
    }));
    document.querySelectorAll("[data-tpl-del]").forEach((b) => (b.onclick = async () => {
      try { S.boot.templates = await native("deleteTemplate", { id: b.dataset.tplDel }); renderMain(); } catch (e) { fail(e); }
    }));
    if (!S.editTemplate) return;
    const pull = () => {
      const t = S.editTemplate;
      t.title = $("#te-title").value; t.icon = $("#te-icon").value; t.description = $("#te-desc").value;
      document.querySelectorAll("[data-sec-title]").forEach((i) => (t.sections[+i.dataset.secTitle].title = i.value));
      document.querySelectorAll("[data-sec-desc]").forEach((i) => (t.sections[+i.dataset.secDesc].description = i.value));
    };
    on("#te-add", () => { pull(); S.editTemplate.sections.push({ title: "", description: "" }); renderMain(); });
    document.querySelectorAll("[data-sec-del]").forEach((b) => (b.onclick = () => { pull(); S.editTemplate.sections.splice(+b.dataset.secDel, 1); renderMain(); }));
    on("#te-cancel", () => { S.editTemplate = null; renderMain(); });
    on("#te-save", async () => {
      pull();
      const t = { ...S.editTemplate, sections: S.editTemplate.sections.filter((x) => x.title.trim()) };
      if (!t.sections.length) return toast("Add at least one section heading.", "warning");
      try { S.boot.templates = await native("saveTemplate", { template: t }); S.editTemplate = null; renderMain(); } catch (e) { fail(e); }
    });
  }

  async function refreshCur() {
    if (!S.cur) return;
    const fresh = await native("getSession", { id: S.cur.id });
    const keep = { notes: S.cur.notes, title: S.titleDirty ? S.cur.title : fresh.title };
    S.cur = { ...fresh, ...keep };
    renderMain();
    refreshList();
  }

  // ---------- events from Swift ----------
  window.__nativeEvent = function ({ name, payload }) {
    if (name === "session") {
      refreshList();
      if (S.cur && S.cur.id === payload.id) refreshCur().catch(() => {});
    } else if (name === "summary_delta") {
      if (S.cur && S.cur.id === payload.id) {
        S.cur.summary = (S.cur.summary || "") + payload.text;
        const body = $("#summary-body");
        if (body && S.tab === "summary") body.innerHTML = window.renderMarkdown(S.cur.summary);
        else if (S.tab === "summary" && S.view === "note") renderMain();
      }
    } else if (name === "tick") {
      S.rec.seconds = payload.seconds;
      const t = $("#rec-time"); if (t) t.textContent = fmtClock(payload.seconds);
    } else if (name === "level") {
      const bars = document.querySelectorAll("#bars i");
      const v = Math.min(1, payload.value * 8);
      bars.forEach((b, i) => (b.style.height = 3 + Math.round(15 * v * (0.55 + 0.45 * Math.sin(Date.now() / 120 + i * 1.7) ** 2)) + "px"));
    } else if (name === "toast") {
      toast(payload.message, payload.kind);
    } else if (name === "navigate") {
      S.rec = { id: payload.id, seconds: 0, level: 0 };
      refreshList().then(() => openSession(payload.id)).catch(fail);
    }
  };

  document.addEventListener("keydown", (e) => {
    if (e.metaKey && e.key.toLowerCase() === "n") { e.preventDefault(); newNote().catch(fail); }
    if (e.metaKey && e.key === ",") { e.preventDefault(); S.view = "settings"; render(); }
  });

  // ---------- boot ----------
  async function boot() {
    shell();
    renderSidebar();
    try {
      S.boot = await native("state");
      if (S.boot.recordingSessionId) S.rec.id = S.boot.recordingSessionId;
      await refreshList();
      if (!S.boot.hasAssemblyKey || !S.boot.hasDeepseekKey) { S.view = "setup"; render(); return; }
      S.view = "note";
      if (S.sessions.length) await openSession(S.sessions[0].id); else render();
    } catch (e) { fail(e); }
  }
  window.__hypernote = { S, render, boot };
  boot();
})();
