import {
  StudioInstance,
  PluginInfoResponse,
  PORT_RANGE_START,
  PORT_RANGE_END,
  PING_TIMEOUT,
} from "./types.js";

/**
 * Scans localhost ports to find running Roblox Studio plugin instances.
 * Each Studio plugin listens on a unique port in the configured range.
 */
export class StudioScanner {
  private knownStudios: Map<string, StudioInstance> = new Map();

  /**
   * Ping a single port to check if a Studio plugin is running there.
   */
  private async pingPort(port: number): Promise<StudioInstance | null> {
    const controller = new AbortController();
    const timeout = setTimeout(() => controller.abort(), PING_TIMEOUT);

    try {
      const res = await fetch(`http://localhost:${port}/info`, {
        signal: controller.signal,
      });

      if (!res.ok) return null;

      const data = (await res.json()) as PluginInfoResponse;
      if (!data.success) return null;

      return {
        id: data.studioId || `studio-${port}`,
        port,
        placeName: data.placeName || "Unknown Place",
        placeId: data.placeId || undefined,
        gameId: data.gameId || undefined,
        lastSeen: Date.now(),
      };
    } catch {
      return null;
    } finally {
      clearTimeout(timeout);
    }
  }

  /**
   * Scan all ports in range and return every active Studio instance found.
   */
  async scan(): Promise<StudioInstance[]> {
    const promises: Promise<StudioInstance | null>[] = [];

    for (let port = PORT_RANGE_START; port <= PORT_RANGE_END; port++) {
      promises.push(this.pingPort(port));
    }

    const results = await Promise.all(promises);
    const active: StudioInstance[] = [];

    for (const result of results) {
      if (result) {
        this.knownStudios.set(result.id, result);
        active.push(result);
      }
    }

    return active;
  }

  /**
   * Get a previously-discovered studio by ID.
   */
  getStudio(id: string): StudioInstance | undefined {
    return this.knownStudios.get(id);
  }

  /**
   * Get all known studios (from last scan).
   */
  getAllKnown(): StudioInstance[] {
    return Array.from(this.knownStudios.values());
  }
}
