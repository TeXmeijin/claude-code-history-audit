import { beforeAll, describe, expect, it } from "bun:test";
import { mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const SCRIPT = join(
  dirname(fileURLToPath(import.meta.url)),
  "..",
  "scripts",
  "redact-claude-history-secrets.sh",
);

/**
 * A single redaction expectation. `input` is the raw line content fed through
 * the redactor; `contains` / `absent` are asserted against the redacted output.
 */
type Case = {
  name: string;
  input: string;
  contains?: string[];
  absent?: string[];
};

/**
 * Runs every case through the real redaction script in one pass and returns the
 * redacted JSONL lines keyed by case name. The script is exercised end-to-end
 * (--apply) against a throwaway Claude config dir, exactly as a user would run it.
 */
function redact(cases: Case[]): Map<string, string> {
  const root = mkdtempSync(join(tmpdir(), "redact-test-"));
  try {
    const projectDir = join(root, "projects", "suite");
    mkdirSync(projectDir, { recursive: true });
    const file = join(projectDir, "cases.jsonl");
    const jsonl = cases
      .map((c) => JSON.stringify({ case: c.name, text: c.input }))
      .join("\n");
    writeFileSync(file, jsonl + "\n");

    const proc = Bun.spawnSync([
      "bash",
      SCRIPT,
      "--config-dir",
      root,
      "--all",
      "--apply",
      "--quiet",
    ]);
    if (proc.exitCode !== 0) {
      throw new Error(`redaction script exited ${proc.exitCode}: ${proc.stderr.toString()}`);
    }

    const byName = new Map<string, string>();
    for (const line of readFileSync(file, "utf8").split("\n")) {
      if (!line) continue;
      byName.set(JSON.parse(line).case, line);
    }
    return byName;
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
}

function runSuite(title: string, cases: Case[]): void {
  describe(title, () => {
    let redacted: Map<string, string>;
    beforeAll(() => {
      redacted = redact(cases);
    });

    for (const c of cases) {
      it(c.name, () => {
        const line = redacted.get(c.name);
        expect(line).toBeDefined();
        for (const needle of c.contains ?? []) {
          expect(line!).toContain(needle);
        }
        for (const needle of c.absent ?? []) {
          expect(line!).not.toContain(needle);
        }
      });
    }
  });
}

// Secret-shaped test inputs are assembled from fragments (string concatenation /
// template interpolation) so the committed source NEVER contains a contiguous
// secret pattern. This is what keeps GitHub secret scanning, gitleaks, and push
// protection from flagging these (entirely synthetic) fixtures — none of them can
// match a pattern that is split across `+` or `${}`. At runtime the redactor still
// receives the full, matchable value. The "example" tokens also make each value
// obviously fake to a human reader.
const E = "example";
const SAK = "EXAMPLEAWSSECRETKEYDONOTUSE" + "EXAMPLE" + "000000"; // 40 base64-ish chars
const AKIA = "AKIA" + "EXAMPLE" + "000000000"; // AKIA + 16 upper/digits
const JWT = `eyJ${E}HEADER.${E}PAYLOAD.${E}SIGNATURE`;

runSuite("AWS secret access key", [
  // Level A: a labeled SAK value is replaced regardless of surrounding chars.
  { name: "level-a-equals", input: `AWS_SECRET_ACCESS_KEY=${SAK}`, contains: ["<AWS_SECRET_ACCESS_KEY>"], absent: ["EXAMPLEAWSSECRET"] },
  { name: "level-a-json", input: `{"aws_secret_access_key":"${SAK}"}`, contains: ["<AWS_SECRET_ACCESS_KEY>"], absent: ["EXAMPLEAWSSECRET"] },
  { name: "level-a-yaml", input: `aws-secret-access-key: '${SAK}'`, contains: ["<AWS_SECRET_ACCESS_KEY>"], absent: ["EXAMPLEAWSSECRET"] },

  // Level B: a bare 40-char value is replaced when an AKIA/ASIA id is on the line.
  {
    name: "level-b-pair",
    input: `export AWS_ACCESS_KEY_ID=${AKIA}; export aws_sak=${SAK}`,
    contains: ["<AWS_ACCESS_KEY_ID>", "<AWS_SECRET_ACCESS_KEY>"],
    absent: [AKIA, "EXAMPLEAWSSECRET"],
  },
  // Level B excludes 40-char git SHA1 hashes even when AKIA is present.
  {
    name: "level-b-sha1-excluded",
    input: `commit ${AKIA} rev=deadbeefdeadbeefdeadbeefdeadbeefdeadbeef prev=cafebabecafebabecafebabecafebabecafebabe`,
    contains: ["<AWS_ACCESS_KEY_ID>", "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef", "cafebabecafebabecafebabecafebabecafebabe"],
    absent: ["<AWS_SECRET_ACCESS_KEY>"],
  },

  // Negatives: nothing should be mistaken for a SAK.
  { name: "negative-jwt-only", input: `token=${JWT}`, contains: ["<JWT>"], absent: ["<AWS_SECRET_ACCESS_KEY>"] },
  { name: "negative-bare-40-no-akia", input: `hash=${SAK}`, contains: [SAK], absent: ["<AWS_SECRET_ACCESS_KEY>"] },
  { name: "negative-sha1-no-akia", input: "git rev abcdef0123abcdef0123abcdef0123abcdef0123 short=deadbeef", contains: ["abcdef0123abcdef0123abcdef0123abcdef0123"], absent: ["<AWS_SECRET_ACCESS_KEY>"] },
]);

runSuite("Provider secrets", [
  { name: "github-token-ghp", input: `export GH_TOKEN=ghp_${E}${E}${E}000`, contains: ["<GITHUB_TOKEN>"], absent: ["ghp_example"] },
  { name: "github-token-gho", input: `oauth gho_${E}${E}${E}000 used`, contains: ["<GITHUB_TOKEN>"], absent: ["gho_example"] },
  { name: "github-fine-grained", input: `token: github_pat_${E}${E}${E}000`, contains: ["<GITHUB_FINE_GRAINED_TOKEN>"], absent: ["github_pat_example"] },
  { name: "anthropic-key", input: `ANTHROPIC_API_KEY=sk-ant-api03-${E}-${E}-${E}`, contains: ["<ANTHROPIC_KEY>"], absent: ["sk-ant-api03-example"] },
  { name: "openai-project-key", input: `OPENAI_API_KEY=sk-proj-${E}-${E}-${E}`, contains: ["<OPENAI_KEY>"], absent: ["sk-proj-example"] },
  { name: "openai-key", input: `key sk-${E}${E}${E}${E}0000 here`, contains: ["<OPENAI_KEY>"], absent: ["sk-exampleexample"] },
  { name: "stripe-key", input: `STRIPE_SECRET=sk_live_${E}${E}${E}0`, contains: ["<STRIPE_KEY>"], absent: ["sk_live_example"] },
  { name: "google-api-key", input: `maps AIza${E}_${E}_${E}_${E}_000 end`, contains: ["<GOOGLE_API_KEY>"], absent: ["AIzaexample"] },
  { name: "slack-token", input: `slack xoxb-${E}-${E}-${E}-00`, contains: ["<SLACK_TOKEN>"], absent: ["xoxb-example"] },
  { name: "jwt-standalone", input: `auth ${JWT}`, contains: ["<JWT>"], absent: ["eyJexampleHEADER"] },
  { name: "db-url-credentials", input: `DATABASE_URL=postgres://${E}user:${E}password@db.example.com:5432/app`, contains: ["<DB_CREDENTIALS>"], absent: ["examplepassword"] },
  { name: "private-key-block", input: `key -----BEGIN RSA PRIVATE KEY-----${E.toUpperCase()}FAKEKEYDONOTUSE-----END RSA PRIVATE KEY-----`, contains: ["<PRIVATE_KEY_BLOCK>"], absent: ["EXAMPLEFAKEKEYDONOTUSE"] },

  // Negative: an ordinary URL with no credentials must pass through untouched.
  { name: "negative-plain-url", input: "docs https://example.com/path?ref=main no secret here", contains: ["https://example.com/path?ref=main"], absent: ["<DB_CREDENTIALS>"] },
]);
