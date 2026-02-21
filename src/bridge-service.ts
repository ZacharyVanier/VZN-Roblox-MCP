import { randomUUID } from "crypto";
import { REQUEST_TIMEOUT } from "./types.js";

interface PendingRequest {
  id: string;
  endpoint: string;
  data: unknown;
  timestamp: number;
  resolve: (value: unknown) => void;
  reject: (error: Error) => void;
  timeoutId: ReturnType<typeof setTimeout>;
}

/**
 * Per-studio request queue with Promise resolution.
 * Each studio gets its own queue so commands route to the correct plugin.
 */
export class BridgeService {
  private queues: Map<string, Map<string, PendingRequest>> = new Map();

  /**
   * Queue a command for a specific studio. Returns a Promise that resolves
   * when the plugin picks up the command, executes it, and posts the result.
   */
  sendRequest(studioId: string, endpoint: string, data: unknown): Promise<unknown> {
    const requestId = randomUUID();

    if (!this.queues.has(studioId)) {
      this.queues.set(studioId, new Map());
    }

    return new Promise((resolve, reject) => {
      const timeoutId = setTimeout(() => {
        const queue = this.queues.get(studioId);
        if (queue?.has(requestId)) {
          queue.delete(requestId);
          reject(new Error(`Request timed out after ${REQUEST_TIMEOUT}ms (studio: ${studioId.slice(0, 8)}...)`));
        }
      }, REQUEST_TIMEOUT);

      const request: PendingRequest = {
        id: requestId,
        endpoint,
        data,
        timestamp: Date.now(),
        resolve,
        reject,
        timeoutId,
      };

      this.queues.get(studioId)!.set(requestId, request);
    });
  }

  /**
   * Get the oldest pending request for a studio (called by HTTP /poll).
   */
  getPendingRequest(studioId: string): { requestId: string; endpoint: string; data: unknown } | null {
    const queue = this.queues.get(studioId);
    if (!queue || queue.size === 0) return null;

    let oldest: PendingRequest | null = null;
    for (const req of queue.values()) {
      if (!oldest || req.timestamp < oldest.timestamp) {
        oldest = req;
      }
    }

    if (oldest) {
      return { requestId: oldest.id, endpoint: oldest.endpoint, data: oldest.data };
    }
    return null;
  }

  /**
   * Resolve a pending request with the plugin's response.
   */
  resolveRequest(requestId: string, studioId: string, response: unknown): void {
    const queue = this.queues.get(studioId);
    const request = queue?.get(requestId);
    if (request) {
      clearTimeout(request.timeoutId);
      queue!.delete(requestId);
      request.resolve(response);
    }
  }

  /**
   * Reject a pending request with an error from the plugin.
   */
  rejectRequest(requestId: string, studioId: string, error: string): void {
    const queue = this.queues.get(studioId);
    const request = queue?.get(requestId);
    if (request) {
      clearTimeout(request.timeoutId);
      queue!.delete(requestId);
      request.reject(new Error(error));
    }
  }

  /**
   * Clear all pending requests for a studio (on disconnect).
   */
  clearStudio(studioId: string): void {
    const queue = this.queues.get(studioId);
    if (queue) {
      for (const [, req] of queue) {
        clearTimeout(req.timeoutId);
        req.reject(new Error("Studio disconnected"));
      }
      queue.clear();
      this.queues.delete(studioId);
    }
  }

  /**
   * Clear all pending requests across all studios.
   */
  clearAll(): void {
    for (const studioId of Array.from(this.queues.keys())) {
      this.clearStudio(studioId);
    }
  }
}
