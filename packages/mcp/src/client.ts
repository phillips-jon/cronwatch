/** A small HTTP client for the JSON API that @cronwatch/sdk mounts. */
export interface ApiClientOptions {
  /** Where the routes are mounted, e.g. https://app.example.com/cronwatch */
  baseUrl: string;
  token: string | null;
  fetch?: typeof fetch;
}

export class ApiError extends Error {
  constructor(message: string, readonly status: number) {
    super(message);
    this.name = "ApiError";
  }
}

export class ApiClient {
  private readonly base: string;
  private readonly token: string | null;
  private readonly fetchFn: typeof fetch;

  constructor(options: ApiClientOptions) {
    this.base = options.baseUrl.replace(/\/+$/, "");
    this.token = options.token;
    this.fetchFn = options.fetch ?? fetch;
  }

  async call<T = unknown>(method: string, path: string, body?: unknown): Promise<T> {
    const headers: Record<string, string> = { accept: "application/json" };
    if (this.token) headers.authorization = `Bearer ${this.token}`;
    if (body !== undefined) headers["content-type"] = "application/json";
    const response = await this.fetchFn(`${this.base}/api${path}`, {
      method,
      headers,
      body: body === undefined ? undefined : JSON.stringify(body),
    });
    const text = await response.text();
    let data: unknown = null;
    try {
      data = text ? JSON.parse(text) : null;
    } catch {
      throw new ApiError(`${method} ${path} answered ${response.status} with a non-JSON body: ${text.slice(0, 200)}`, response.status);
    }
    if (!response.ok) {
      const message = typeof data === "object" && data && "error" in data ? String((data as { error: unknown }).error) : response.statusText;
      throw new ApiError(`${method} ${path} failed (${response.status}): ${message}`, response.status);
    }
    return data as T;
  }
}
