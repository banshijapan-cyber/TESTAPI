# TESTAPI — Backlog API integration

A small TypeScript client for the [Backlog REST API](https://developer.nulab.com/docs/backlog/) that connects using a space API key and lists projects and issues.

## Setup

1. Install dependencies:

   ```sh
   npm install
   ```

2. Copy `.env.example` to `.env` and fill in your values:

   ```sh
   cp .env.example .env
   ```

   - `BACKLOG_SPACE_DOMAIN` — your Backlog space domain, e.g. `hrs-market.backlog.jp`
   - `BACKLOG_API_KEY` — your Backlog API key (Personal Settings → API in Backlog)

   `.env` is gitignored — never commit your real API key.

3. Run:

   ```sh
   npm run dev
   ```

   This connects to your space, then prints your projects and the issues in the first project.

## Usage in code

```ts
import { BacklogClient } from "./src/backlogClient.js";

const client = new BacklogClient({
  spaceDomain: process.env.BACKLOG_SPACE_DOMAIN!,
  apiKey: process.env.BACKLOG_API_KEY!,
});

const projects = await client.getProjects();
const issues = await client.getIssues({ projectId: [projects[0].id] });
```

## Scripts

- `npm run dev` — run directly with `tsx`
- `npm run build` — compile to `dist/`
- `npm start` — run the compiled build
- `npm run due-today [PROJECT_KEY]` — list open issues due today in a project (defaults to `NEO`)

Example:

```sh
npm run due-today NEO
```
