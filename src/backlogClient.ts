export interface BacklogClientOptions {
  spaceDomain: string;
  apiKey: string;
}

export interface BacklogProject {
  id: number;
  projectKey: string;
  name: string;
  [key: string]: unknown;
}

export interface BacklogIssue {
  id: number;
  issueKey: string;
  summary: string;
  status: { id: number; name: string };
  [key: string]: unknown;
}

export interface GetIssuesParams {
  projectId?: number[];
  statusId?: number[];
  count?: number;
  offset?: number;
  [key: string]: unknown;
}

export class BacklogApiError extends Error {
  constructor(public status: number, public statusText: string, public body: string) {
    super(`Backlog API error ${status} ${statusText}: ${body}`);
    this.name = "BacklogApiError";
  }
}

export class BacklogClient {
  private readonly baseUrl: string;
  private readonly apiKey: string;

  constructor(options: BacklogClientOptions) {
    const domain = options.spaceDomain.replace(/^https?:\/\//, "").replace(/\/$/, "");
    this.baseUrl = `https://${domain}/api/v2`;
    this.apiKey = options.apiKey;
  }

  private async request<T>(path: string, params: Record<string, unknown> = {}): Promise<T> {
    const url = new URL(`${this.baseUrl}${path}`);
    url.searchParams.set("apiKey", this.apiKey);

    for (const [key, value] of Object.entries(params)) {
      if (value === undefined) continue;
      if (Array.isArray(value)) {
        for (const item of value) url.searchParams.append(`${key}[]`, String(item));
      } else {
        url.searchParams.set(key, String(value));
      }
    }

    const response = await fetch(url.toString());
    const body = await response.text();

    if (!response.ok) {
      throw new BacklogApiError(response.status, response.statusText, body);
    }

    return JSON.parse(body) as T;
  }

  getSpace(): Promise<Record<string, unknown>> {
    return this.request("/space");
  }

  getProjects(): Promise<BacklogProject[]> {
    return this.request("/projects");
  }

  getProject(projectIdOrKey: string | number): Promise<BacklogProject> {
    return this.request(`/projects/${encodeURIComponent(String(projectIdOrKey))}`);
  }

  getIssues(params: GetIssuesParams = {}): Promise<BacklogIssue[]> {
    return this.request("/issues", params);
  }
}
