import fs from "node:fs";

const apiUrl = process.env.GITHUB_API_URL || "https://api.github.com";
const sourceRepo = process.env.GITHUB_REPOSITORY;
const sourceToken = process.env.GITHUB_TOKEN;
const targetToken = process.env.TARGET_REPO_TOKEN;

if (!sourceRepo) {
  throw new Error("GITHUB_REPOSITORY is required.");
}
if (!sourceToken) {
  throw new Error("GITHUB_TOKEN is required.");
}

const [sourceOwner, sourceName] = sourceRepo.split("/");
const event = JSON.parse(fs.readFileSync(process.env.GITHUB_EVENT_PATH, "utf8"));

async function request(token, path, options = {}) {
  const response = await fetch(`${apiUrl}${path}`, {
    ...options,
    headers: {
      Accept: "application/vnd.github+json",
      Authorization: `Bearer ${token}`,
      "X-GitHub-Api-Version": "2022-11-28",
      "Content-Type": "application/json",
      ...(options.headers || {}),
    },
  });

  if (response.status === 204) {
    return null;
  }

  const text = await response.text();
  const data = text ? JSON.parse(text) : null;
  if (!response.ok) {
    const message = data?.message || response.statusText;
    throw new Error(`${options.method || "GET"} ${path} failed: ${response.status} ${message}`);
  }
  return data;
}

async function getIssue() {
  if (event.issue) {
    return event.issue;
  }

  const issueNumber = process.env.ISSUE_NUMBER;
  if (!issueNumber) {
    throw new Error("ISSUE_NUMBER is required for workflow_dispatch.");
  }

  return request(sourceToken, `/repos/${sourceOwner}/${sourceName}/issues/${issueNumber}`);
}

function isTrustedIssueAuthor(issue) {
  return ["OWNER", "MEMBER", "COLLABORATOR"].includes(issue.author_association);
}

function parseIssueForm(body) {
  const sections = new Map();
  let current = null;
  let lines = [];

  for (const line of (body || "").split(/\r?\n/)) {
    const heading = line.match(/^###\s+(.+?)\s*$/);
    if (heading) {
      if (current) {
        sections.set(current, cleanValue(lines.join("\n")));
      }
      current = heading[1].trim();
      lines = [];
    } else if (current) {
      lines.push(line);
    }
  }

  if (current) {
    sections.set(current, cleanValue(lines.join("\n")));
  }

  return sections;
}

function cleanValue(value) {
  const trimmed = value.trim();
  return trimmed === "_No response_" ? "" : trimmed;
}

function field(sections, name, fallback = "") {
  return sections.get(name) || fallback;
}

function parseRepoUrl(value) {
  const match = value.trim().match(/^https:\/\/github\.com\/([^/\s]+)\/([^/\s#?]+?)(?:\.git)?(?:[/?#].*)?$/i);
  if (!match) {
    throw new Error(`Repository URL must look like https://github.com/EKI-inc/repo-name. Received: ${value}`);
  }

  const owner = match[1];
  const repo = match[2];
  if (owner !== "EKI-inc") {
    throw new Error(`Gallery automation only writes to EKI-inc repositories. Received owner: ${owner}`);
  }

  return { owner, repo, fullName: `${owner}/${repo}` };
}

function normalizeKey(value) {
  return value
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, "_")
    .replace(/^_+|_+$/g, "");
}

function listFromText(value) {
  return value
    .split(/\r?\n|,/)
    .map((line) => line.trim().replace(/^[-*]\s+/, ""))
    .filter(Boolean);
}

function maintainersFromText(value) {
  return listFromText(value).map((line) => {
    const cleaned = line.replace(/^@/, "");
    if (cleaned.includes("/")) {
      return { team: cleaned };
    }
    if (/^[A-Za-z0-9-]+$/.test(cleaned)) {
      return { github: cleaned };
    }
    return { name: line };
  });
}

function parseKeyValueText(value) {
  const output = {};
  for (const line of value.split(/\r?\n/)) {
    const cleaned = line.trim().replace(/^[-*]\s+/, "");
    if (!cleaned) {
      continue;
    }
    const match = cleaned.match(/^([^:]+):\s*(.+)$/);
    if (match) {
      output[normalizeKey(match[1])] = match[2].trim();
    }
  }
  return output;
}

function stakeholdersFromText(value) {
  const parsed = parseKeyValueText(value);
  return {
    project_owner: parsed.project_owner || parsed.owner || "TBD",
    technical_owner: parsed.technical_owner || "TBD",
    it_contact: parsed.it_contact || parsed.it || "TBD",
  };
}

function projectFromText(value) {
  const text = value.trim();
  if (!text || text.toLowerCase() === "unknown") {
    return { id: null, label: "unknown" };
  }

  const parts = text.split("/").map((part) => part.trim()).filter(Boolean);
  if (parts.length >= 2) {
    return { id: parts[0], label: parts.slice(1).join(" / ") };
  }
  return { id: null, label: text };
}

function selectedCheckboxLabels(value) {
  return value
    .split(/\r?\n/)
    .map((line) => line.match(/^-\s+\[[xX]\]\s+(.+)$/)?.[1]?.trim())
    .filter(Boolean);
}

function dataRiskFromText(value) {
  const selected = selectedCheckboxLabels(value);
  const has = (needle) => selected.some((label) => label.toLowerCase().includes(needle));
  const unknown = has("unknown");
  const flag = (needle) => (has(needle) ? "yes" : unknown ? "unknown" : "no");

  return {
    client_confidential: flag("client confidential"),
    regulated_or_restricted: has("regulated") || has("sensitive") || has("restricted") ? "yes" : unknown ? "unknown" : "no",
    secrets_or_credentials: has("secrets") || has("credentials") || has("service accounts") || has("api tokens") ? "yes" : unknown ? "unknown" : "no",
    notes: selected.length ? selected.join("; ") : "TBD",
  };
}

function parseDeployment(value) {
  const environments = [];
  let resourceGroup = "TBD";

  for (const line of value.split(/\r?\n/)) {
    const cleaned = line.trim().replace(/^[-*]\s+/, "");
    if (!cleaned) {
      continue;
    }

    const envMatch = cleaned.match(/^([^:]+):\s*(.*)$/);
    const name = envMatch ? envMatch[1].trim() : "environment";
    const rest = envMatch ? envMatch[2].trim() : cleaned;
    const url = rest.match(/https?:\/\/[^\s,)]+/)?.[0] || "TBD";
    const status = rest.match(/\bstatus\s+([^,;]+)/i)?.[1]?.trim() || "TBD";
    const rg = rest.match(/\bresource group\s+([A-Za-z0-9_.-]+)/i)?.[1]?.trim();
    if (rg) {
      resourceGroup = rg;
    }
    environments.push({ name, url, status });
  }

  return {
    platform: "TBD",
    azure: {
      resource_group: resourceGroup,
    },
    environments: environments.length ? environments : [{ name: "production", url: "TBD", status: "unknown" }],
  };
}

function mergeDefaults(defaults, values) {
  return { ...defaults, ...Object.fromEntries(Object.entries(values).filter(([, value]) => value)) };
}

function notesFromText(value) {
  const lines = listFromText(value);
  return lines.length ? lines : [];
}

function buildInventory(issue, sections) {
  const repository = parseRepoUrl(field(sections, "Repository URL"));
  const docs = mergeDefaults(
    {
      readme: "README.md",
      architecture: "TBD",
      runbook: "TBD",
      support_notes: "TBD",
    },
    parseKeyValueText(field(sections, "Documentation links"))
  );
  const badges = mergeDefaults(
    {
      build: "TBD",
      test: "TBD",
      code_scanning: "TBD",
      release: "TBD",
    },
    parseKeyValueText(field(sections, "Health and automation signals"))
  );
  const linked = mergeDefaults(
    {
      intake_issue: "TBD",
      project_board: "TBD",
      current_milestone: "TBD",
    },
    parseKeyValueText(field(sections, "Linked records"))
  );

  const notes = notesFromText(field(sections, "Gallery notes"));
  notes.push(`Generated from ${issue.html_url}`);

  return {
    repository,
    inventory: {
      schema_version: 1,
      item: {
        type: field(sections, "Inventory item type", "application"),
        name: field(sections, "Short stable ID"),
        display_name: field(sections, "Display name"),
        description: field(sections, "Description"),
        repository: {
          owner: repository.owner,
          name: repository.repo,
          url: `https://github.com/${repository.fullName}`,
        },
        status: field(sections, "Lifecycle status", "unknown"),
        project: projectFromText(field(sections, "Project ID or label")),
        maintainers: maintainersFromText(field(sections, "Maintainers")),
        stakeholders: stakeholdersFromText(field(sections, "Stakeholders and support contacts")),
        capabilities: listFromText(field(sections, "Capabilities")),
        data_and_risk: dataRiskFromText(field(sections, "Data, privacy, and policy flags")),
        deployment: parseDeployment(field(sections, "Deployment environments and URLs")),
        documentation: docs,
        badges,
        planning: linked,
        notes,
      },
    },
  };
}

function yamlScalar(value) {
  if (value === null) {
    return "null";
  }
  if (typeof value === "number" || typeof value === "boolean") {
    return String(value);
  }
  const text = String(value);
  if (text === "") {
    return '""';
  }
  if (text.includes("\n")) {
    return null;
  }
  return JSON.stringify(text);
}

function toYaml(value, indent = 0) {
  const pad = " ".repeat(indent);
  if (Array.isArray(value)) {
    if (!value.length) {
      return `${pad}[]`;
    }
    return value
      .map((item) => {
        if (item && typeof item === "object" && !Array.isArray(item)) {
          const entries = Object.entries(item);
          if (!entries.length) {
            return `${pad}- {}`;
          }
          const [firstKey, firstValue] = entries[0];
          const firstScalar = yamlScalar(firstValue);
          const firstLine = firstScalar === null
            ? `${pad}- ${firstKey}: |\n${blockScalar(String(firstValue), indent + 4)}`
            : `${pad}- ${firstKey}: ${firstScalar}`;
          const rest = entries.slice(1).map(([key, nestedValue]) => renderObjectEntry(key, nestedValue, indent + 2));
          return [firstLine, ...rest].join("\n");
        }
        const scalar = yamlScalar(item);
        if (scalar === null) {
          return `${pad}- |\n${blockScalar(String(item), indent + 2)}`;
        }
        return `${pad}- ${scalar}`;
      })
      .join("\n");
  }

  if (value && typeof value === "object") {
    return Object.entries(value)
      .map(([key, nestedValue]) => renderObjectEntry(key, nestedValue, indent))
      .join("\n");
  }

  const scalar = yamlScalar(value);
  return scalar === null ? `${pad}|\n${blockScalar(String(value), indent + 2)}` : `${pad}${scalar}`;
}

function renderObjectEntry(key, value, indent) {
  const pad = " ".repeat(indent);
  const scalar = yamlScalar(value);
  if (scalar !== null) {
    return `${pad}${key}: ${scalar}`;
  }
  if (typeof value === "string") {
    return `${pad}${key}: |\n${blockScalar(value, indent + 2)}`;
  }
  return `${pad}${key}:\n${toYaml(value, indent + 2)}`;
}

function blockScalar(value, indent) {
  const pad = " ".repeat(indent);
  return value.split(/\r?\n/).map((line) => `${pad}${line}`).join("\n");
}

function encodeBase64(value) {
  return Buffer.from(value, "utf8").toString("base64");
}

async function getDefaultBranch(owner, repo) {
  const repository = await request(targetToken, `/repos/${owner}/${repo}`);
  return repository.default_branch;
}

async function getRef(owner, repo, branch) {
  return request(targetToken, `/repos/${owner}/${repo}/git/ref/heads/${branch}`);
}

async function ensureBranch(owner, repo, defaultBranch, branch) {
  const defaultRef = await getRef(owner, repo, defaultBranch);
  try {
    await getRef(owner, repo, branch);
  } catch (error) {
    if (!String(error.message).includes("404")) {
      throw error;
    }
    await request(targetToken, `/repos/${owner}/${repo}/git/refs`, {
      method: "POST",
      body: JSON.stringify({
        ref: `refs/heads/${branch}`,
        sha: defaultRef.object.sha,
      }),
    });
  }
}

async function getExistingFileSha(owner, repo, path, branch) {
  try {
    const file = await request(targetToken, `/repos/${owner}/${repo}/contents/${encodeURIComponent(path).replaceAll("%2F", "/")}?ref=${encodeURIComponent(branch)}`);
    return file.sha;
  } catch (error) {
    if (String(error.message).includes("404")) {
      return undefined;
    }
    throw error;
  }
}

async function upsertInventoryFile(owner, repo, branch, yaml, issue) {
  const path = ".github/eki-inventory.yml";
  const sha = await getExistingFileSha(owner, repo, path, branch);
  const message = sha
    ? `Update gallery inventory from issue #${issue.number}`
    : `Add gallery inventory from issue #${issue.number}`;

  await request(targetToken, `/repos/${owner}/${repo}/contents/${encodeURIComponent(path).replaceAll("%2F", "/")}`, {
    method: "PUT",
    body: JSON.stringify({
      message,
      content: encodeBase64(yaml),
      branch,
      ...(sha ? { sha } : {}),
    }),
  });
}

async function ensurePullRequest(owner, repo, branch, defaultBranch, displayName, issue) {
  const pulls = await request(targetToken, `/repos/${owner}/${repo}/pulls?state=open&head=${owner}:${encodeURIComponent(branch)}`);
  if (pulls.length) {
    return pulls[0];
  }

  return request(targetToken, `/repos/${owner}/${repo}/pulls`, {
    method: "POST",
    body: JSON.stringify({
      title: `Add gallery inventory for ${displayName}`,
      head: branch,
      base: defaultBranch,
      body: [
        "Adds or updates `.github/eki-inventory.yml` from a submitted Application gallery inventory issue.",
        "",
        `Source issue: ${issue.html_url}`,
        "",
        "After this PR merges, the central gallery builder can discover the inventory file from the repository default branch.",
      ].join("\n"),
    }),
  });
}

async function commentOnIssue(issue, body) {
  await request(sourceToken, `/repos/${sourceOwner}/${sourceName}/issues/${issue.number}/comments`, {
    method: "POST",
    body: JSON.stringify({ body }),
  });
}

function slug(value) {
  return value
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, "-")
    .replace(/^-+|-+$/g, "")
    .slice(0, 48);
}

async function main() {
  const issue = await getIssue();
  if (!issue.title.startsWith("Gallery inventory:")) {
    console.log(`Skipping non-gallery inventory issue: ${issue.title}`);
    return;
  }
  if (!isTrustedIssueAuthor(issue)) {
    await commentOnIssue(
      issue,
      "Gallery inventory automation skipped this issue because the author is not an organization member or repository collaborator."
    );
    return;
  }
  if (!targetToken) {
    await commentOnIssue(
      issue,
      "Gallery inventory automation is not fully configured. Add a repository secret named `ORG_INVENTORY_PR_TOKEN` with permission to create branches, write contents, and open pull requests in target `EKI-inc` repositories."
    );
    throw new Error("ORG_INVENTORY_PR_TOKEN is not configured.");
  }

  const sections = parseIssueForm(issue.body || "");
  const { repository, inventory } = buildInventory(issue, sections);
  const defaultBranch = await getDefaultBranch(repository.owner, repository.repo);
  const branch = `gallery-inventory/issue-${issue.number}-${slug(inventory.item.name || inventory.item.display_name)}`;
  const yaml = `${toYaml(inventory)}\n`;

  await ensureBranch(repository.owner, repository.repo, defaultBranch, branch);
  await upsertInventoryFile(repository.owner, repository.repo, branch, yaml, issue);
  const pull = await ensurePullRequest(
    repository.owner,
    repository.repo,
    branch,
    defaultBranch,
    inventory.item.display_name,
    issue
  );

  await commentOnIssue(
    issue,
    [
      "Created or updated the gallery inventory pull request.",
      "",
      `Target repository: ${repository.fullName}`,
      `Inventory path: \`.github/eki-inventory.yml\``,
      `Pull request: ${pull.html_url}`,
    ].join("\n")
  );
}

main().catch(async (error) => {
  console.error(error);
  try {
    const issue = await getIssue();
    if (issue?.number) {
      await commentOnIssue(issue, `Gallery inventory automation failed: ${error.message}`);
    }
  } catch (commentError) {
    console.error("Failed to comment on issue:", commentError);
  }
  process.exit(1);
});
