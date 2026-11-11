import { EventEmitter } from 'node:events';
import type { Logging } from 'homebridge';
import { withBindings } from '@stoprocent/noble';
import type { Characteristic, Noble, Peripheral } from '@stoprocent/noble';
import {
  COMMAND_CHARACTERISTIC_UUID,
  SERVICE_UUID,
  STATUS_CHARACTERISTIC_UUID,
  encode,
  isPoplightName,
  wantsResponse,
  type Command,
} from './protocol';

export type BindingName = 'default' | 'hci' | 'dbus' | 'mac' | 'win';

const CONNECT_TIMEOUT_MS = 20_000;
const DISCOVER_TIMEOUT_MS = 20_000;
const SUBSCRIBE_TIMEOUT_MS = 10_000;
const DISCONNECT_TIMEOUT_MS = 5_000;
const WRITE_TIMEOUT_MS = 5_000;
const SCAN_START_TIMEOUT_MS = 10_000;
const SCAN_DEBOUNCE_MS = 1_000;
/** Spacing between retries when the controller refuses to start scanning. */
const SCAN_RETRY_MS = 10_000;
/** Minimum spacing between connection attempts triggered by hearing a light advertise. */
const REHEARD_MIN_INTERVAL_MS = 5_000;
/** On-demand links: how long to keep retrying a connection while a command is waiting. */
const ON_DEMAND_DEADLINE_MS = 30_000;
const DEFAULT_IDLE_MS = 30_000;
const CCCD_UUID = '2902';

/**
 * True when noble talks to the controller directly over a Linux HCI socket. In that mode the
 * light's notification setup needs special handling (see `PoplightLink.enableNotifications`).
 */
export function usesHciSocket(bindings: BindingName): boolean {
  return bindings === 'hci' || (bindings === 'default' && process.platform === 'linux');
}

function errorMessage(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
}

/**
 * A Bluetooth controller establishes one LE connection at a time. Two lights discovered in the
 * same scan burst would otherwise race each other (the HCI binding then fails one with
 * "Unknown Connection Identifier" and the other with "Connection Failed to be Established"), so
 * connection attempts from all links go through this queue. It also means at most one
 * LE Create Connection is ever pending, which is what makes cancelling one safe.
 */
let connectQueue: Promise<unknown> = Promise.resolve();
let connectsPending = 0;
/** Called when the last queued connection attempt settles; the scanner uses it to resume scanning. */
let onConnectQueueIdle: (() => void) | undefined;
function serializedConnect<T>(task: () => Promise<T>): Promise<T> {
  connectsPending += 1;
  const run = connectQueue.then(task, task);
  connectQueue = run.catch(() => undefined).then(() => {
    connectsPending -= 1;
    if (connectsPending === 0) {
      onConnectQueueIdle?.();
    }
  });
  return run;
}

function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

function withTimeout<T>(promise: Promise<T>, ms: number, what: string): Promise<T> {
  return new Promise<T>((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error(`${what} timed out after ${ms / 1000}s`)), ms);
    promise.then(
      (value) => {
        clearTimeout(timer);
        resolve(value);
      },
      (error) => {
        clearTimeout(timer);
        reject(error);
      },
    );
  });
}

/**
 * Thin wrapper around noble: powers on, scans, and reports every Poplight advertisement.
 *
 * Every advertisement is emitted, not just the first per light: the platform decides whether a
 * report is a new light or a known one coming back after a power cycle.
 */
export class PoplightScanner extends EventEmitter {
  private started = false;
  private scanTimer?: NodeJS.Timeout;
  private scanFailures = 0;
  private readonly noble: Noble;
  /** Pass to `PoplightLink` so it enables notifications in a way this binding can handle. */
  readonly hciSocket: boolean;

  constructor(
    private readonly log: Logging,
    bindings: BindingName = 'default',
  ) {
    super();
    this.noble = withBindings(bindings as 'default');
    this.hciSocket = usesHciSocket(bindings);
  }

  async start(): Promise<void> {
    if (this.started) {
      return;
    }
    this.started = true;
    const noble = this.noble;
    noble.on('discover', (peripheral: Peripheral) => {
      const name = peripheral.advertisement?.localName;
      if (!isPoplightName(name)) {
        return;
      }
      this.emit('poplight', peripheral);
    });
    noble.on('stateChange', (state: string) => {
      this.log.debug(`Bluetooth state: ${state}`);
      if (state === 'poweredOn') {
        void this.scan();
      }
    });
    // The HCI binding turns scanning off to establish a connection and never turns it back on,
    // so a second light would stay undiscovered. Resume once all pending attempts have settled.
    onConnectQueueIdle = () => this.ensureScanning();
    this.log.info('Waiting for Bluetooth…');
    try {
      await noble.waitForPoweredOnAsync();
    } catch (error) {
      // The adapter may come up later (rfkill, a slow USB dongle, a failed reset). noble does
      // not always emit stateChange for that, so poll the state until it does.
      this.log.warn(`Bluetooth not ready: ${errorMessage(error)}. Will keep checking.`);
      await new Promise<void>((resolve) => {
        const timer = setInterval(() => {
          if (noble.state === 'poweredOn') {
            clearInterval(timer);
            resolve();
          }
        }, 5_000);
      });
      this.log.info('Bluetooth is up');
    }
    await this.scan();
  }

  /** (Re)start scanning. */
  async scan(): Promise<void> {
    try {
      // A previous process may have left the adapter scanning; the HCI binding then fails to
      // set scan parameters with EIO. Clearing first makes start reliable on Linux.
      // noble resolves these only when the controller confirms; while it is busy connecting
      // the confirmation may never come, so bound the waits and let the next request try again.
      await withTimeout(this.noble.stopScanningAsync(), SCAN_START_TIMEOUT_MS, 'scan stop').catch(() => undefined);
      // allowDuplicates: the name only travels in the scan response. With duplicates filtered,
      // noble reports a peripheral once, and if that report happened to be built from two bare
      // ADV_IND packets (scan response lost) the light stays nameless and invisible for the rest
      // of the session. Every report is cheap to filter, so take them all; this is also what
      // lets a known light be heard again after a power cycle.
      await withTimeout(this.noble.startScanningAsync([], true), SCAN_START_TIMEOUT_MS, 'scan start');
      this.scanFailures = 0;
      this.log.debug('Scanning for POP_Light');
    } catch (error) {
      // Seen on Linux when the kernel has an extended scan of its own running (legacy scan
      // commands are then disallowed) or the controller is wedged. Nothing else would ever
      // start scanning again, so keep trying; the service's adapter reset on restart clears it.
      this.scanFailures += 1;
      this.log.warn(`Scan failed: ${errorMessage(error)}. Retrying in ${SCAN_RETRY_MS / 1000}s`);
      if (this.scanFailures === 3 && this.hciSocket) {
        this.log.warn('Scanning keeps failing. If this persists, restart Homebridge so the adapter is reset.');
      }
      this.ensureScanning(SCAN_RETRY_MS);
    }
  }

  /**
   * Ask for scanning to be running shortly. noble stops scanning whenever it connects to a
   * peripheral and never resumes on its own, so this is called after every connection event.
   * Calls within a second are coalesced; a pending request is never delayed further.
   */
  ensureScanning(delayMs: number = SCAN_DEBOUNCE_MS): void {
    if (!this.started || this.scanTimer) {
      return;
    }
    this.scanTimer = setTimeout(() => {
      this.scanTimer = undefined;
      void this.scan();
    }, delayMs);
  }
}

export interface LinkEvents {
  connected: () => void;
  disconnected: (reason?: string) => void;
  connectFailed: (error: Error) => void;
  status: (data: Buffer) => void;
}

export interface LinkOptions {
  /** See `usesHciSocket`. Defaults to what the platform's default binding uses. */
  hciSocket?: boolean;
  /**
   * true (default): hold the connection and reconnect whenever it drops.
   * false: on demand. Connect when a command needs it and disconnect after `idleMs` without one.
   * The light asks for a 15 ms connection interval with no latency, so a held connection wakes
   * its radio about 67 times a second and drains the battery even while the lamp is off.
   */
  persistent?: boolean;
  /** On-demand only: how long the connection is kept after the last command. */
  idleMs?: number;
}

export interface SendOptions {
  /** On-demand only: keep the connection at least this long after the command (default `idleMs`). */
  holdMs?: number;
  /** On-demand only: retry the connection until the deadline (default) or try just once. */
  retry?: boolean;
}

/**
 * One light's connection: discovers FFB1/FFB2 and writes commands. A persistent link reconnects
 * when dropped; an on-demand link connects for a command and lets go when idle.
 */
export class PoplightLink extends EventEmitter {
  private command?: Characteristic;
  private status?: Characteristic;
  private connecting?: Promise<void>;
  private reconnectTimer?: NodeJS.Timeout;
  private attempts = 0;
  private lastAttemptAt = 0;
  private closed = false;
  public connected = false;
  private readonly hciSocket: boolean;
  private readonly persistent: boolean;
  private readonly idleMs: number;
  private idleTimer?: NodeJS.Timeout;
  private idleDeadline = 0;
  /** Commands between "started" and "written"; the idle timer never fires under one. */
  private inFlight = 0;
  private ensuring?: Promise<void>;
  private releasing?: Promise<void>;
  /** Tail of the write queue; see `send`. */
  private writeChain: Promise<unknown> = Promise.resolve();
  /** Peripheral instances that already carry the stray-connection listener. */
  private readonly watched = new WeakSet<Peripheral>();

  constructor(
    public peripheral: Peripheral,
    private readonly log: Logging,
    private readonly label: string,
    options: LinkOptions = {},
  ) {
    super();
    this.hciSocket = options.hciSocket ?? usesHciSocket('default');
    this.persistent = options.persistent ?? true;
    this.idleMs = options.idleMs ?? DEFAULT_IDLE_MS;
  }

  /**
   * The light was heard advertising again (noble may hand out a new peripheral instance).
   * If the link is waiting out its reconnect backoff, connect now instead; returns true when
   * it did. Lights advertise several times a second, so attempts triggered this way are spaced
   * at least `REHEARD_MIN_INTERVAL_MS` apart.
   */
  replacePeripheral(peripheral: Peripheral): boolean {
    if (this.connected || this.closed) {
      return false;
    }
    const previous = this.peripheral;
    this.peripheral = peripheral;
    if (this.connecting) {
      // An attempt is in flight. If it is aimed at a stale instance of this light, cancel it so
      // the controller stops waiting for a device that is gone; doConnect's catch reschedules
      // and the next advertisement (or the backoff timer) connects to the new instance.
      if (previous !== peripheral && previous.state === 'connecting') {
        previous.cancelConnect();
      }
      return false;
    }
    if (!this.persistent) {
      return false; // the next command connects to the new instance
    }
    if (!this.reconnectTimer || Date.now() - this.lastAttemptAt < REHEARD_MIN_INTERVAL_MS) {
      return false;
    }
    clearTimeout(this.reconnectTimer);
    this.reconnectTimer = undefined;
    this.attempts = 0;
    void this.connect().catch(() => undefined);
    return true;
  }

  async connect(): Promise<void> {
    if (this.connected) {
      return;
    }
    if (this.connecting) {
      return this.connecting;
    }
    this.connecting = this.doConnect().finally(() => {
      this.connecting = undefined;
    });
    return this.connecting;
  }

  private async doConnect(): Promise<void> {
    // Read the peripheral once the queue reaches us: it may have been replaced while waiting.
    let p = this.peripheral;
    try {
      await serializedConnect(async () => {
        if (this.closed) {
          throw new Error('link closed');
        }
        if (this.releasing) {
          await this.releasing; // an idle disconnect is still completing
        }
        p = this.peripheral;
        this.lastAttemptAt = Date.now();
        this.watchForStrayConnection(p);
        if (p.state === 'connected') {
          // A link from an attempt that was reported as failed but completed afterwards.
          this.log.debug(`${this.label}: adopting an existing link`);
        } else {
          this.log.debug(`${this.label}: connecting (attempt ${this.attempts + 1})`);
          await withTimeout(p.connectAsync(), CONNECT_TIMEOUT_MS, 'connect');
        }
        this.log.debug(`${this.label}: link up, discovering FFB0`);
        const { characteristics } = await withTimeout(
          p.discoverSomeServicesAndCharacteristicsAsync(
            [SERVICE_UUID],
            [COMMAND_CHARACTERISTIC_UUID, STATUS_CHARACTERISTIC_UUID],
          ),
          DISCOVER_TIMEOUT_MS,
          'service discovery',
        );
        this.command = characteristics.find((c) => c.uuid === COMMAND_CHARACTERISTIC_UUID);
        this.status = characteristics.find((c) => c.uuid === STATUS_CHARACTERISTIC_UUID);
        if (!this.command) {
          throw new Error('FFB1 characteristic not found');
        }
        if (this.status) {
          this.status.removeAllListeners('data');
          this.status.on('data', (data: Buffer) => this.emit('status', data));
          this.log.debug(`${this.label}: enabling FFB2 notifications`);
          await withTimeout(this.enableNotifications(this.status), SUBSCRIBE_TIMEOUT_MS, 'notification setup');
        }
      });
      p.removeAllListeners('disconnect');
      p.once('disconnect', (reason?: string) => this.handleDisconnect(reason));
      this.connected = true;
      this.attempts = 0;
      if (this.reconnectTimer) {
        clearTimeout(this.reconnectTimer);
        this.reconnectTimer = undefined;
      }
      this.log.info(`${this.label}: connected`);
      this.emit('connected');
    } catch (error) {
      this.attempts += 1;
      this.connected = false;
      this.log.warn(`${this.label}: connect failed: ${errorMessage(error)}`);
      await this.abandonAttempt(p);
      this.scheduleReconnect();
      this.emit('connectFailed', error);
      throw error;
    }
  }

  /**
   * On Linux the kernel sometimes cancels noble's connection request and then completes the
   * connection itself. noble reports the attempt as failed, and a moment later the peripheral
   * turns up connected with nobody using it. Left alone, that link would hold the light's radio
   * awake until the next command or poll, so drop it as soon as it appears.
   */
  private watchForStrayConnection(p: Peripheral): void {
    if (this.watched.has(p)) {
      return;
    }
    this.watched.add(p);
    p.on('connect', (error?: unknown) => {
      if (error || this.connected || this.connecting || this.closed || p !== this.peripheral) {
        return;
      }
      this.log.debug(`${this.label}: dropping a connection that completed after its attempt failed`);
      void withTimeout(p.disconnectAsync(), DISCONNECT_TIMEOUT_MS, 'disconnect').catch(() => undefined);
    });
  }

  /**
   * Tear down whatever the failed attempt left behind, without ever blocking.
   *
   * If the link never came up, the controller still has an LE Create Connection pending for
   * a light that is not there (the spec gives it no timeout). It has to be cancelled: a
   * disconnect has no handle to act on, noble writes one for handle 0, the controller rejects
   * it, and the disconnect promise never settles, which used to freeze this link for good
   * whenever a light lost power. Cancelling also lets noble move on to the next queued
   * connection and frees the radio to scan again.
   */
  private async abandonAttempt(p: Peripheral): Promise<void> {
    if (p.state === 'connecting') {
      p.cancelConnect();
      return;
    }
    if (p.state === 'connected' || p.state === 'disconnecting') {
      try {
        await withTimeout(p.disconnectAsync(), DISCONNECT_TIMEOUT_MS, 'disconnect');
      } catch (error) {
        this.log.debug(`${this.label}: ${errorMessage(error)}`);
      }
    }
  }

  /**
   * Turn on FFB2 notifications.
   *
   * noble's HCI binding implements `subscribe` by locating the Client Characteristic
   * Configuration descriptor with an ATT Read By Type request. The Poplight answers that request
   * with a malformed response (it reports the descriptor handle with a zero-length value), which
   * makes noble throw or hang. Discovering the descriptor with Find Information and writing
   * 0x0001 to it directly sidesteps the broken request. CoreBluetooth and BlueZ refuse direct
   * writes to that descriptor and handle the quirk themselves, so those bindings keep using
   * `subscribe`.
   */
  private async enableNotifications(characteristic: Characteristic): Promise<void> {
    if (this.hciSocket) {
      const descriptors = await characteristic.discoverDescriptorsAsync();
      const cccd = descriptors.find((d) => d.uuid === CCCD_UUID);
      if (cccd) {
        await cccd.writeValueAsync(Buffer.from([0x01, 0x00]));
        return;
      }
      this.log.debug(`${this.label}: no CCCD found, falling back to subscribe`);
    }
    await characteristic.subscribeAsync();
  }

  private handleDisconnect(reason?: string): void {
    const idle = this.releasing !== undefined;
    this.connected = false;
    this.command = undefined;
    this.status = undefined;
    this.clearIdleTimer();
    this.log.info(`${this.label}: disconnected${idle ? ' (idle)' : reason ? ` (${reason})` : ''}`);
    this.emit('disconnected', idle ? 'idle' : reason);
    this.scheduleReconnect();
  }

  /** Persistent links only; an on-demand link reconnects when the next command arrives. */
  private scheduleReconnect(): void {
    if (this.closed || this.reconnectTimer || !this.persistent) {
      return;
    }
    const delay = Math.min(60_000, 2_000 * 2 ** Math.min(this.attempts, 5));
    this.reconnectTimer = setTimeout(() => {
      this.reconnectTimer = undefined;
      void this.connect().catch(() => undefined);
    }, delay);
  }

  async send(command: Command, options: SendOptions = {}): Promise<void> {
    const data = encode(command);
    if (!data) {
      throw new Error('command not supported by the light');
    }
    this.inFlight += 1;
    try {
      if (!this.connected) {
        await this.ensureConnected(options.retry ?? true);
      }
      // One write at a time. noble completes a write through a single per-characteristic
      // callback slot, so a second write issued before the first finishes takes the slot over
      // and the first promise never settles. Both bytes reach the light, but the caller hangs,
      // and with it the idle timer of an on-demand link. The timeout covers a lost response.
      const write = this.writeChain.then(() => {
        if (!this.command) {
          throw new Error('not connected');
        }
        const withoutResponse =
          !wantsResponse(command) && this.command.properties.includes('writeWithoutResponse');
        this.log.debug(`${this.label}: write ${data.toString('hex')}${withoutResponse ? '' : ' (with response)'}`);
        return withTimeout(this.command.writeAsync(data, withoutResponse), WRITE_TIMEOUT_MS, 'write');
      });
      this.writeChain = write.catch(() => undefined);
      await write;
    } finally {
      this.inFlight -= 1;
      this.touch(options.holdMs ?? this.idleMs);
    }
  }

  /**
   * Connect for a waiting command. A persistent link has its own reconnect loop, so one attempt
   * is enough there. An on-demand link has none: the first attempt often fails on Linux (the
   * kernel contends for the raw HCI socket), so keep trying for a while before giving up.
   * Concurrent commands share one loop.
   */
  private ensureConnected(retry: boolean): Promise<void> {
    if (this.persistent || !retry) {
      return this.connect();
    }
    if (!this.ensuring) {
      this.ensuring = (async () => {
        const deadline = Date.now() + ON_DEMAND_DEADLINE_MS;
        let delay = 500;
        for (;;) {
          try {
            await this.connect();
            return;
          } catch (error) {
            if (this.closed || Date.now() + delay >= deadline) {
              throw error;
            }
            await sleep(delay);
            delay = Math.min(delay * 2, 4_000);
          }
        }
      })().finally(() => {
        this.ensuring = undefined;
      });
    }
    return this.ensuring;
  }

  /** On-demand links: keep the connection for at least `holdMs` more, then let it go. */
  private touch(holdMs: number): void {
    if (this.persistent || this.closed) {
      return;
    }
    this.idleDeadline = Math.max(this.idleDeadline, Date.now() + holdMs);
    this.armIdleTimer();
  }

  private armIdleTimer(): void {
    this.clearIdleTimer();
    this.idleTimer = setTimeout(() => {
      this.idleTimer = undefined;
      if (this.inFlight > 0 || this.connecting) {
        this.idleDeadline = Date.now() + 1_000;
        this.armIdleTimer();
        return;
      }
      void this.release();
    }, Math.max(0, this.idleDeadline - Date.now()));
  }

  private clearIdleTimer(): void {
    if (this.idleTimer) {
      clearTimeout(this.idleTimer);
      this.idleTimer = undefined;
    }
  }

  /** Idle disconnect. A command arriving meanwhile waits for it to finish, then reconnects. */
  private async release(): Promise<void> {
    if (!this.connected || this.releasing) {
      return;
    }
    const p = this.peripheral;
    // Commands from here on must take the connect path, not write to a link that is going away.
    this.connected = false;
    this.command = undefined;
    this.status = undefined;
    this.log.debug(`${this.label}: idle, disconnecting`);
    this.releasing = withTimeout(p.disconnectAsync(), DISCONNECT_TIMEOUT_MS, 'disconnect')
      .catch((error) => {
        // noble never confirmed, so handleDisconnect did not run; do its bookkeeping here.
        this.log.debug(`${this.label}: ${errorMessage(error)}`);
        p.removeAllListeners('disconnect');
        this.emit('disconnected', 'idle');
      })
      .then(() => {
        this.releasing = undefined;
      });
    await this.releasing;
  }

  async close(): Promise<void> {
    this.closed = true;
    this.clearIdleTimer();
    if (this.reconnectTimer) {
      clearTimeout(this.reconnectTimer);
      this.reconnectTimer = undefined;
    }
    if (this.peripheral.state === 'connecting') {
      this.peripheral.cancelConnect();
      return;
    }
    await withTimeout(this.peripheral.disconnectAsync(), DISCONNECT_TIMEOUT_MS, 'disconnect').catch(() => undefined);
  }
}
