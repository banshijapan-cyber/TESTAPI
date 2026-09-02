import "dotenv/config";
import { BacklogClient, BacklogApiError } from "./backlogClient.js";

const spaceDomain = process.env.BACKLOG_SPACE_DOMAIN;
const apiKey = process.env.BACKLOG_API_KEY;

if (!spaceDomain || !apiKey) {
  console.error("Missing BACKLOG_SPACE_DOMAIN or BACKLOG_API_KEY. Copy .env.example to .env and fill in your values.");
  process.exit(1);
}

const client = new BacklogClient({ spaceDomain, apiKey });

async function main() {
  try {
    const space = await client.getSpace();
    console.log(`Connected to Backlog space: ${space.name} (${space.spaceKey})`);

    const projects = await client.getProjects();
    console.log(`\nFound ${projects.length} project(s):`);
    for (const project of projects) {
      console.log(`  - [${project.projectKey}] ${project.name}`);
    }

    if (projects.length > 0) {
      const firstProject = projects[0];
      const issues = await client.getIssues({ projectId: [firstProject.id], count: 20 });
      console.log(`\nFound ${issues.length} issue(s) in ${firstProject.projectKey}:`);
      for (const issue of issues) {
        console.log(`  - [${issue.issueKey}] ${issue.summary} (${issue.status.name})`);
      }
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
