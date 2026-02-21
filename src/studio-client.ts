import { StudioInstance, PluginResponse, PING_TIMEOUT } from "./types.js";

/**
 * HTTP client for communicating with a specific Roblox Studio plugin instance.
 */
export class StudioClient {
  private baseUrl: string;

  constructor(public readonly studio: StudioInstance) {
    this.baseUrl = `http://localhost:${studio.port}`;
  }

  /**
   * Send a raw request to the Studio plugin.
   */
  private async request(
    endpoint: string,
    method: string = "GET",
    body?: unknown
  ): Promise<PluginResponse> {
    const controller = new AbortController();
    const timeout = setTimeout(() => controller.abort(), PING_TIMEOUT * 4);

    try {
      const res = await fetch(`${this.baseUrl}${endpoint}`, {
        method,
        headers: body ? { "Content-Type": "application/json" } : undefined,
        body: body ? JSON.stringify(body) : undefined,
        signal: controller.signal,
      });

      return (await res.json()) as PluginResponse;
    } catch (err) {
      return {
        success: false,
        error: `Failed to reach Studio on port ${this.studio.port}: ${err}`,
      };
    } finally {
      clearTimeout(timeout);
    }
  }

  /** Execute Luau code in Studio and return the result. */
  async execute(code: string): Promise<PluginResponse> {
    return this.request("/execute", "POST", { command: code });
  }

  /** Get children of an instance by path. */
  async getChildren(path: string): Promise<PluginResponse> {
    return this.request("/children", "POST", { path });
  }

  /** Get properties of an instance by path. */
  async getProperties(path: string): Promise<PluginResponse> {
    return this.request("/properties", "POST", { path });
  }

  /** Get the source of a script by path. */
  async getScriptSource(path: string): Promise<PluginResponse> {
    return this.request("/scriptSource", "POST", { path });
  }

  /** Set the source of a script by path. */
  async setScriptSource(path: string, source: string): Promise<PluginResponse> {
    return this.request("/setScriptSource", "POST", { path, source });
  }

  /** Create a new instance in Studio. */
  async createInstance(
    className: string,
    parent: string,
    name?: string,
    properties?: Record<string, unknown>
  ): Promise<PluginResponse> {
    return this.request("/create", "POST", { className, parent, name, properties });
  }

  /** Delete an instance by path. */
  async deleteInstance(path: string): Promise<PluginResponse> {
    return this.request("/delete", "POST", { path });
  }

  /** Set a property on an instance. */
  async setProperty(
    path: string,
    property: string,
    value: unknown
  ): Promise<PluginResponse> {
    return this.request("/setProperty", "POST", { path, property, value });
  }

  /** Search for instances by name or class. */
  async search(query: string, className?: string): Promise<PluginResponse> {
    return this.request("/search", "POST", { query, className });
  }
}
