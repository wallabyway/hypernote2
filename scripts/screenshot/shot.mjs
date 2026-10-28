// Renders web/ with sample data (harness.html) and writes docs/screenshot-*.png.
// Set CHROME_PATH to a Chrome / chrome-headless-shell binary.
import puppeteer from "puppeteer-core";
import { fileURLToPath } from "node:url";
import path from "node:path";

const here = path.dirname(fileURLToPath(import.meta.url));
const docs = path.resolve(here, "../../docs");
const executablePath = process.env.CHROME_PATH
  || "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome";

const browser = await puppeteer.launch({
  executablePath, headless: "shell",
  args: ["--allow-file-access-from-files", "--no-sandbox", "--disable-gpu"],
});
const page = await browser.newPage();
await page.setViewport({ width: 1120, height: 740, deviceScaleFactor: 2 });
const errors = [];
page.on("pageerror", (e) => errors.push(String(e)));

await page.goto("file://" + path.join(here, "harness.html"));
await page.waitForSelector(".md");
await page.screenshot({ path: path.join(docs, "screenshot-summary.png") });

await page.click('[data-tab="transcript"]');
await page.waitForSelector(".utt");
await page.screenshot({ path: path.join(docs, "screenshot-transcript.png") });

// Obsidian export: the button on the summary plus its confirmation toast...
await page.click('[data-tab="summary"]');
await page.waitForSelector("#export-summary");
await page.click("#export-summary");
await page.waitForSelector(".toast.success");
await page.screenshot({ path: path.join(docs, "screenshot-obsidian.png") });

// ...and the folder setting.
await page.evaluate(() => document.querySelectorAll(".toast").forEach((t) => t.remove()));
await page.click("#settings-btn");
await page.waitForSelector("#export-path");
await page.mouse.move(1100, 20);
await page.evaluate(() => document.querySelector("#export-path").closest(".section").scrollIntoView({ block: "center" }));
await page.screenshot({ path: path.join(docs, "screenshot-obsidian-settings.png") });

await browser.close();
if (errors.length) { console.error(errors); process.exit(1); }
console.log("wrote", docs);
