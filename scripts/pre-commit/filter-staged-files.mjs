#!/usr/bin/env node
// Filters staged file paths for pre-commit lint/format hooks.
import path from "node:path";

/**
 * Prints selected files as NUL-delimited tokens to stdout.
 *
 * Usage:
 *   node scripts/pre-commit/filter-staged-files.mjs lint -- <files...>
 *   git diff --cached --name-only -z | node scripts/pre-commit/filter-staged-files.mjs format --stdin0
 *   git check-ignore --stdin -z --non-matching --verbose | node scripts/pre-commit/filter-staged-files.mjs unignored --stdin0
 *
 * Keep this dependency-free: the pre-commit hook runs in many environments.
 */

const mode = process.argv[2];
const rawArgs = process.argv.slice(3);
const stdin0 = rawArgs.length === 1 && rawArgs[0] === "--stdin0";
const files = rawArgs[0] === "--" ? rawArgs.slice(1) : rawArgs;

if (mode !== "lint" && mode !== "format" && mode !== "unignored") {
  process.stderr.write("usage: filter-staged-files.mjs <lint|format> (-- <files...>|--stdin0)\n");
  process.exit(2);
}

if (!stdin0 && rawArgs.includes("--stdin0")) {
  process.stderr.write("--stdin0 cannot be combined with path arguments\n");
  process.exit(2);
}

async function readNulDelimitedStdin() {
  const chunks = [];
  for await (const chunk of process.stdin) {
    chunks.push(chunk);
  }
  const input = Buffer.concat(chunks).toString("utf8");
  return input.split("\0").slice(0, -1);
}

const lintExts = new Set([".ts", ".tsx", ".mts", ".cts", ".js", ".jsx", ".mjs", ".cjs"]);
const formatExts = new Set([
  ".ts",
  ".tsx",
  ".mts",
  ".cts",
  ".js",
  ".jsx",
  ".mjs",
  ".cjs",
  ".md",
  ".mdx",
]);
const formatIgnoredPathPatterns = [/^extensions\/[^/]+\/src\/host\/.+\/[^/]+\.bundle\.js$/u];

const shouldSelect = (filePath) => {
  const ext = path.extname(filePath).toLowerCase();
  if (mode === "lint") {
    return lintExts.has(ext);
  }
  if (formatIgnoredPathPatterns.some((pattern) => pattern.test(filePath))) {
    return false;
  }
  return formatExts.has(ext);
};

const inputFiles = stdin0 ? await readNulDelimitedStdin() : files;

if (mode === "unignored") {
  if (inputFiles.length % 4 !== 0) {
    process.stderr.write("git check-ignore returned an incomplete NUL record\n");
    process.exit(1);
  }
  for (let index = 0; index < inputFiles.length; index += 4) {
    const [source, lineNumber, pattern, file] = inputFiles.slice(index, index + 4);
    if (source === "" && lineNumber === "" && pattern === "" && file) {
      process.stdout.write(file);
      process.stdout.write("\0");
    }
  }
} else {
  for (const file of inputFiles) {
    if (shouldSelect(file)) {
      process.stdout.write(file);
      process.stdout.write("\0");
    }
  }
}
