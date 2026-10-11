// Today's knowledge generation, planned and costed against live data -- and
// nothing written. Run by Scripts/knowledge-generation-dry-run.sh, which
// takes the cut through the linked CLI first; this reads R2 only through the
// bucket's public host (GET and HEAD), with no credentials at all.
//
//   deno run --allow-read --allow-net=<host> Scripts/knowledge-generation-dry-run.ts \
//       <cut.json> <cut-ms> <budget.json> <demand.json> <host>

import { dryRunGeneration, type Budget, type Cut, type Demand } from "../supabase/functions/_shared/generations.ts";

const [cutPath, cutMs, budgetPath, demandPath, host] = Deno.args;
if (!host) {
  console.error("usage: knowledge-generation-dry-run.ts <cut.json> <cut-ms> <budget.json> <demand.json> <host>");
  Deno.exit(2);
}

/// The CLI's answer: one row, one column, inside a JSON envelope.
function firstValue(path: string, column: string): unknown {
  const text = Deno.readTextFileSync(path);
  const envelope = JSON.parse(text.slice(text.indexOf("{"), text.lastIndexOf("}") + 1));
  if (!envelope.rows?.length) throw new Error(`${path}: no rows (${String(envelope.error?.message ?? "").slice(0, 300)})`);
  return envelope.rows[0][column];
}

const url = (key: string) => `https://${host}/${key.split("/").map(encodeURIComponent).join("/")}`;

const report = await dryRunGeneration({
  cut: () => Promise.resolve({ cut: firstValue(cutPath, "cut") as Cut, ms: Number(cutMs) }),
  async getObject(key) {
    const response = await fetch(url(key));
    if (response.status === 404) { await response.body?.cancel(); return null; }
    if (!response.ok) throw new Error(`r2 get ${key} answered ${response.status}`);
    return await response.text();
  },
  async exists(key) {
    const response = await fetch(url(key), { method: "HEAD" });
    await response.body?.cancel();
    if (response.status === 404) return false;
    if (!response.ok) throw new Error(`r2 head ${key} answered ${response.status}`);
    return true;
  },
  now: () => new Date(),
}, JSON.parse(Deno.readTextFileSync(demandPath)) as Demand, { budget: firstValue(budgetPath, "b") as Budget });

console.log(JSON.stringify(report, null, 2));
if (report.status !== "ready") Deno.exit(1);
