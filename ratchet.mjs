// Reads a `biome lint --reporter=json` report and sets every erroring rule to "warn" in biome.json.
// Files that fail to parse are added to files.includes as exclusions.
import { readFileSync, writeFileSync } from "node:fs";

const [reportPath, configPath] = process.argv.slice(2);
const raw = readFileSync(reportPath, "utf8");
const report = JSON.parse(raw.slice(raw.indexOf("{")));
const config = JSON.parse(readFileSync(configPath, "utf8"));

const rules = {};
const unparsable = new Set();
for (const d of report.diagnostics ?? []) {
  if (d.severity !== "error") continue;
  const parts = (d.category ?? "").split("/");
  if (parts[0] === "lint" && parts.length === 3) {
    const [, group, rule] = parts;
    rules[group] ??= {};
    rules[group][rule] = "warn";
  } else if (parts[0] === "parse" && d.location?.path) {
    unparsable.add(typeof d.location.path === "string" ? d.location.path : d.location.path.file);
  }
}

if (Object.keys(rules).length) {
  config.linter = { rules };
}
if (unparsable.size) {
  // A repo-level files.includes replaces the shared one, so carry the shared exclusions over
  const base = JSON.parse(readFileSync("node_modules/@aplfme/lint-config/biome.json", "utf8"));
  config.files = {
    includes: [...base.files.includes, ...[...unparsable].sort().map((f) => `!${f}`)],
  };
}
writeFileSync(configPath, `${JSON.stringify(config, null, 2)}\n`);

const count = Object.values(rules).reduce((n, g) => n + Object.keys(g).length, 0);
console.log(`ratchet: ${count} rules set to warn, ${unparsable.size} unparsable files excluded`);
