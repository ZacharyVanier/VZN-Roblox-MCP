import { StudioInfo, STUDIO_TIMEOUT } from "./types.js";

/**
 * Tracks all connected Studio plugin instances.
 * Studios register on connect and are pruned if they stop polling.
 */
export class StudioRegistry {
  private studios: Map<string, StudioInfo> = new Map();

  /**
   * Register a new studio (called from HTTP /register).
   */
  register(info: {
    studioId: string;
    placeName: string;
    placeId?: number;
    gameId?: number;
  }): void {
    this.studios.set(info.studioId, {
      ...info,
      registeredAt: Date.now(),
      lastPoll: Date.now(),
    });
  }

  /**
   * Update the last poll timestamp (called from HTTP /poll).
   */
  recordPoll(studioId: string): void {
    const studio = this.studios.get(studioId);
    if (studio) {
      studio.lastPoll = Date.now();
    }
  }

  /**
   * Remove a studio (called from HTTP /disconnect).
   */
  disconnect(studioId: string): void {
    this.studios.delete(studioId);
  }

  /**
   * Get a studio by ID.
   */
  getStudio(studioId: string): StudioInfo | undefined {
    return this.studios.get(studioId);
  }

  /**
   * Get all studios that have polled recently. Prunes stale entries.
   */
  getActiveStudios(): StudioInfo[] {
    const now = Date.now();
    const active: StudioInfo[] = [];

    for (const [id, studio] of this.studios) {
      if (now - studio.lastPoll < STUDIO_TIMEOUT) {
        active.push(studio);
      } else {
        this.studios.delete(id);
      }
    }

    return active;
  }

  /**
   * Check if a studio is still alive (polled recently).
   */
  isAlive(studioId: string): boolean {
    const studio = this.studios.get(studioId);
    if (!studio) return false;
    return Date.now() - studio.lastPoll < STUDIO_TIMEOUT;
  }
}
