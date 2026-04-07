#!/usr/bin/env node
/**
 * Same checks as validate_policies.py — run from bellXinfra/scripts: node validate_policies.mjs
 */
import { readFileSync, existsSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

const dir = join(dirname(fileURLToPath(import.meta.url)), "policies");
const required = ["ecs-task-trust.json", "backend-secrets-read.json"];

for (const name of required) {
  const p = join(dir, name);
  if (!existsSync(p)) {
    console.error("Missing:", p);
    process.exit(1);
  }
  const data = JSON.parse(readFileSync(p, "utf8"));
  if (typeof data !== "object" || data === null || !("Statement" in data)) {
    console.error("Expected object with Statement:", p);
    process.exit(1);
  }
}
console.log("OK:", required.join(", "));
