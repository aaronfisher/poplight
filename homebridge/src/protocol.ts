/**
 * Poplight BLE protocol — TypeScript port of PoplightKit/Protocol (see ../PROTOCOL.md).
 * Pure functions, no Bluetooth dependency.
 */

export const ADVERTISED_NAMES = ['pop_light', 'poplight', 'pop_light'];
export const SERVICE_UUID = 'ffb0';
export const COMMAND_CHARACTERISTIC_UUID = 'ffb1'; // write / write-without-response
export const STATUS_CHARACTERISTIC_UUID = 'ffb2'; // notify

export type Warmth = 'warm' | 'neutral' | 'cool';

export const MIN_BRIGHTNESS = 1;
export const MAX_BRIGHTNESS = 99;
export const TIMER_STEP_MINUTES = 15;
export const MAX_TIMER_MINUTES = 720;

export type Command =
  | { type: 'power'; on: boolean }
  | { type: 'brightness'; value: number }
  | { type: 'warmth'; warmth: Warmth }
  | { type: 'sleepTimer'; minutes: number }
  | { type: 'queryStatus' };

export interface Status {
  on?: boolean;
  brightness?: number;
  warmth?: Warmth;
  batteryPercent?: number;
  batteryRaw?: number;
}

const WARMTH_WIRE: Record<Warmth, number> = { cool: 0, neutral: 1, warm: 2 };

export function warmthFromWire(value: number): Warmth | undefined {
  return (Object.keys(WARMTH_WIRE) as Warmth[]).find((w) => WARMTH_WIRE[w] === value);
}

export function isPoplightName(name: string | undefined): boolean {
  if (!name) {
    return false;
  }
  const lower = name.toLowerCase();
  return ADVERTISED_NAMES.some((n) => lower.includes(n));
}

export function clampBrightness(value: number): number {
  return Math.max(MIN_BRIGHTNESS, Math.min(MAX_BRIGHTNESS, Math.round(value)));
}

/** Minutes → timer index 1…48, rounded to 15-minute steps; undefined for ≤ 0. */
export function timerIndex(minutes: number): number | undefined {
  if (minutes <= 0) {
    return undefined;
  }
  const idx = Math.round(minutes / TIMER_STEP_MINUTES);
  return Math.max(1, Math.min(MAX_TIMER_MINUTES / TIMER_STEP_MINUTES, idx));
}

/** Bytes to write to FFB1, or undefined when the light has no encoding for the command. */
export function encode(command: Command): Buffer | undefined {
  switch (command.type) {
    case 'power':
      return Buffer.from([0x01, 0x01, command.on ? 0x01 : 0x00]);
    case 'brightness':
      return Buffer.from([0x01, 0x02, clampBrightness(command.value)]);
    case 'warmth':
      return Buffer.from([0x01, 0x06, WARMTH_WIRE[command.warmth]]);
    case 'sleepTimer': {
      const idx = timerIndex(command.minutes);
      return idx === undefined ? undefined : Buffer.from([0x02, 0x03, 0x00, idx]);
    }
    case 'queryStatus':
      return Buffer.from([0x01, 0x09, 0x00]);
  }
}

/** The official app writes everything without response except the battery query. */
export function wantsResponse(command: Command): boolean {
  return command.type === 'queryStatus';
}

/** Raw battery byte → percent, as the official app maps it. */
export function batteryPercent(raw: number): number {
  switch (raw) {
    case 80:
      return 100;
    case 60:
      return 75;
    case 40:
      return 50;
    case 20:
      return 25;
    default:
      return Math.max(0, Math.min(100, raw));
  }
}

/**
 * Parse an FFB2 notification. The light echoes every accepted command back on FFB2
 * (`01 01 x`, `01 02 n`, `01 06 v`), and answers the battery query with `01 09 raw`.
 */
export function decodeStatus(data: Buffer | Uint8Array): Status | undefined {
  if (data.length < 3 || data[0] !== 0x01) {
    return undefined;
  }
  switch (data[1]) {
    case 0x01:
      return { on: data[2] === 0x01 };
    case 0x02:
      return { brightness: data[2] };
    case 0x06: {
      const warmth = warmthFromWire(data[2]);
      return warmth ? { warmth } : undefined;
    }
    case 0x09: {
      const raw = data[2];
      return { batteryPercent: batteryPercent(raw), batteryRaw: raw };
    }
    default:
      return undefined;
  }
}

/** HomeKit colour temperature (mireds) ↔ the light's three warmth steps. */
export const WARMTH_MIREDS: Record<Warmth, number> = { cool: 153, neutral: 250, warm: 370 };

export function warmthFromMireds(mireds: number): Warmth {
  let best: Warmth = 'neutral';
  let bestDistance = Infinity;
  for (const w of Object.keys(WARMTH_MIREDS) as Warmth[]) {
    const d = Math.abs(WARMTH_MIREDS[w] - mireds);
    if (d < bestDistance) {
      best = w;
      bestDistance = d;
    }
  }
  return best;
}
