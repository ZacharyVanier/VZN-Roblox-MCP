export interface StudioInstance {
  /** Unique ID for this Studio instance */
  id: string;
  /** Port the Studio plugin is listening on */
  port: number;
  /** Name of the place open in this Studio */
  placeName: string;
  /** Roblox Place ID (if published) */
  placeId?: number;
  /** Roblox Game/Universe ID (if published) */
  gameId?: number;
  /** When this instance was last seen alive */
  lastSeen: number;
}

export interface PluginResponse {
  success: boolean;
  data?: unknown;
  error?: string;
}

export interface PluginInfoResponse {
  success: boolean;
  placeName: string;
  placeId: number;
  gameId: number;
  studioId: string;
}

/** Port range the scanner checks for active Studio plugins */
export const PORT_RANGE_START = 3002;
export const PORT_RANGE_END = 3020;

/** How long to wait for a Studio plugin to respond (ms) */
export const PING_TIMEOUT = 1500;
