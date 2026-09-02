import "dotenv/config";
import { BacklogClient, BacklogApiError } from "./backlogClient.js";

const spaceDomain = process.env.BACKLOG_SPACE_DOMAIN;
const apiKey = process.env.BACKLOG_API_KEY;
const projectKey = process.argv[2] ?? "NEO";

if (!spaceDomain || !apiKey) {
  console.error("Missing BACKLOG_SPACE_DOMAIN or BACKLOG_API_KEY. Copy .env.example to .env and fill in your values.");
  process.exit(1);
}

function todayInSpaceTimezone(): string {
  // Backlog .jp spaces run on JST; adjust here if your space uses a different timezone.
  return new Intl.DateTimeFormat("en-CA", { timeZone: "Asia/Tokyo" }).format(new Date());
}

const client = new BacklogClient({ spaceDomain, apiKey });

async function main() {
  try {
    const project = await client.getProject(projectKey);
    const today = todayInSpaceTimezone();

    const issues = await client.getIssues({
      projectId: [project.id],
      dueDateSince: today,
      dueDateUntil: today,
      count: 100,
    });

    const openIssues = issues.filter((issue) => issue.status.name.toLowerCase() !== "closed");

    if (openIssues.length === 0) {
      console.log(`No open issues due today (${today}) in project ${project.projectKey}.`);
      return;
    }

    console.log(`Issues due today (${today}) in project ${project.projectKey}:`);
    for (const issue of openIssues) {
      const assignee = (issue.assignee as { name?: string } | null)?.name ?? "Unassigned";
      console.log(`  - [${issue.issueKey}] ${issue.summary} — status: ${issue.status.name}, assignee: ${assignee}`);
    }
  } catch (error) {
    if (error instanceof BacklogApiError) {
      console.error(`Backlog API request failed: ${error.message}`);
    } else {
      console.error(error);
    }
    process.exit(1);
  }
}

main();
