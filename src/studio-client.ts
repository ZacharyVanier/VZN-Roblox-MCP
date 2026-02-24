import { BridgeService } from "./bridge-service.js";
import { PluginResponse } from "./types.js";

/**
 * Client for communicating with a specific Roblox Studio plugin instance.
 * Routes all commands through the BridgeService queue.
 */
export class StudioClient {
  constructor(
    public readonly studioId: string,
    private bridge: BridgeService
  ) {}

  /**
   * Send a command to the studio via the bridge queue.
   * The plugin will pick it up on its next poll cycle.
   */
  private async request(endpoint: string, data?: unknown): Promise<PluginResponse> {
    try {
      const result = await this.bridge.sendRequest(this.studioId, endpoint, data || {});
      return result as PluginResponse;
    } catch (err) {
      return {
        success: false,
        error: err instanceof Error ? err.message : String(err),
      };
    }
  }

  /** Execute Luau code in Studio and return the result. */
  async execute(code: string): Promise<PluginResponse> {
    return this.request("execute", { command: code });
  }

  /** Get children of an instance by path. */
  async getChildren(path: string): Promise<PluginResponse> {
    return this.request("getChildren", { path });
  }

  /** Get properties of an instance by path. */
  async getProperties(path: string): Promise<PluginResponse> {
    return this.request("getProperties", { path });
  }

  /** Get the source of a script by path. */
  async getScriptSource(path: string): Promise<PluginResponse> {
    return this.request("getScriptSource", { path });
  }

  /** Set the source of a script by path. */
  async setScriptSource(path: string, source: string): Promise<PluginResponse> {
    return this.request("setScriptSource", { path, source });
  }

  /** Create a new instance in Studio. */
  async createInstance(
    className: string,
    parent: string,
    name?: string,
    properties?: Record<string, unknown>
  ): Promise<PluginResponse> {
    return this.request("createInstance", { className, parent, name, properties });
  }

  /** Delete an instance by path. */
  async deleteInstance(path: string): Promise<PluginResponse> {
    return this.request("deleteInstance", { path });
  }

  /** Set a property on an instance. */
  async setProperty(
    path: string,
    property: string,
    value: unknown
  ): Promise<PluginResponse> {
    return this.request("setProperty", { path, property, value });
  }

  /** Search for instances by name or class. */
  async search(query: string, className?: string): Promise<PluginResponse> {
    return this.request("search", { query, className });
  }

  /** Get accumulated console output from Studio. */
  async getConsoleOutput(): Promise<PluginResponse> {
    return this.request("getConsoleOutput", {});
  }

  /** Clear the console output buffer. */
  async clearConsoleOutput(): Promise<PluginResponse> {
    return this.request("clearConsoleOutput", {});
  }

  /** Get current Studio mode (edit, play, or run). */
  async getStudioMode(): Promise<PluginResponse> {
    return this.request("getStudioMode", {});
  }

  /** Start a playtest. Mode: "play" or "run". */
  async startPlaytest(mode: string): Promise<PluginResponse> {
    return this.request("startPlaytest", { mode });
  }

  /** Stop the current playtest. */
  async stopPlaytest(): Promise<PluginResponse> {
    return this.request("stopPlaytest", {});
  }

}
