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
const DISCONNECT_TIMEOUT_MS = 5_000;
const SCAN_START_TIMEOUT_MS = 10_000;
const SCAN_DEBOUNCE_MS = 1_000;

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
 * report is a new light or a known one coming back after a power cycle. The controller already
 * filters duplicates within one scan session, so this is one event per light per scan.
 */
export class PoplightScanner extends EventEmitter {
  private started = false;
  private scanTimer?: NodeJS.Timeout;
  private readonly noble: Noble;

  constructor(
    private readonly log: Logging,
    bindings: BindingName = 'default',
  ) {
    super();
    this.noble = withBindings(bindings as 'default');
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
      this.log.debug(`Heard ${name} (${peripheral.id}, ${peripheral.rssi} dBm)`);
      this.emit('poplight', peripheral);
    });
    noble.on('stateChange', (state: string) => {
      this.log.debug(`Bluetooth state: ${state}`);
      if (state === 'poweredOn') {
        void this.scan();
      }
    });
    this.log.info('Waiting for Bluetooth…');
    await noble.waitForPoweredOnAsync();
    await this.scan();
  }

  /**
   * (Re)start scanning. Restarting also clears the controller's duplicate filter, so a light
   * that was already reported once is reported again when it reappears.
   */
  async scan(): Promise<void> {
    try {
      // A previous process may have left the adapter scanning; the HCI binding then fails to
      // set scan parameters with EIO. Clearing first makes start reliable on Linux.
      // noble resolves these only when the controller confirms; while it is busy connecting
      // the confirmation may never come, so bound the waits and let the next request try again.
      await withTimeout(this.noble.stopScanningAsync(), SCAN_START_TIMEOUT_MS, 'scan stop').catch(() => undefined);
      await withTimeout(this.noble.startScanningAsync([], false), SCAN_START_TIMEOUT_MS, 'scan start');
      this.log.debug('Scanning for POP_Light');
    } catch (error) {
      this.log.warn(`Scan failed: ${(error as Error).message}`);
    }
  }

  /**
   * Ask for scanning to be running shortly. noble stops scanning whenever it connects to a
   * peripheral and never resumes on its own, so links call this after every connection event.
   * Calls within a second are coalesced.
   */
  ensureScanning(): void {
    if (!this.started || this.scanTimer) {
      return;
    }
    this.scanTimer = setTimeout(() => {
      this.scanTimer = undefined;
      void this.scan();
    }, SCAN_DEBOUNCE_MS);
  }
}

export interface LinkEvents {
  connected: () => void;
  disconnected: (reason?: string) => void;
  connectFailed: (error: Error) => void;
  status: (data: Buffer) => void;
}

/** One light's connection: discovers FFB1/FFB2, writes commands, reconnects when dropped. */
export class PoplightLink extends EventEmitter {
  private command?: Characteristic;
  private status?: Characteristic;
  private connecting?: Promise<void>;
  private reconnectTimer?: NodeJS.Timeout;
  private attempts = 0;
  private closed = false;
  public connected = false;

  constructor(
    public peripheral: Peripheral,
    private readonly log: Logging,
    private readonly label: string,
  ) {
    super();
  }

  /**
   * The light was heard advertising again (noble may hand out a new peripheral instance).
   * Drop any attempt still aimed at the old instance and connect to this one right away
   * instead of waiting out the reconnect backoff.
   */
  replacePeripheral(peripheral: Peripheral): void {
    if (this.connected || this.closed) {
      return;
    }
    const previous = this.peripheral;
    this.peripheral = peripheral;
    this.attempts = 0;
    if (this.reconnectTimer) {
      clearTimeout(this.reconnectTimer);
      this.reconnectTimer = undefined;
    }
    if (this.connecting) {
      // Cancelling rejects the in-flight connectAsync; doConnect's catch then reschedules, but
      // the chained connect below runs first and finds the new peripheral in place.
      if (previous !== peripheral && previous.state === 'connecting') {
        previous.cancelConnect();
      }
      void this.connecting.catch(() => undefined).then(() => this.connect().catch(() => undefined));
      return;
    }
    void this.connect().catch(() => undefined);
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
    const p = this.peripheral;
    this.log.debug(`${this.label}: connecting (attempt ${this.attempts + 1})`);
    try {
      await withTimeout(p.connectAsync(), CONNECT_TIMEOUT_MS, 'connect');
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
        await this.status.subscribeAsync();
      }
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
      this.log.warn(`${this.label}: connect failed: ${(error as Error).message}`);
      await this.abandonAttempt(p);
      this.scheduleReconnect();
      this.emit('connectFailed', error);
      throw error;
    }
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
        this.log.debug(`${this.label}: ${(error as Error).message}`);
      }
    }
  }

  private handleDisconnect(reason?: string): void {
    this.connected = false;
    this.command = undefined;
    this.status = undefined;
    this.log.info(`${this.label}: disconnected${reason ? ` (${reason})` : ''}`);
    this.emit('disconnected', reason);
    this.scheduleReconnect();
  }

  private scheduleReconnect(): void {
    if (this.closed || this.reconnectTimer) {
      return;
    }
    const delay = Math.min(60_000, 2_000 * 2 ** Math.min(this.attempts, 5));
    this.reconnectTimer = setTimeout(() => {
      this.reconnectTimer = undefined;
      void this.connect().catch(() => undefined);
    }, delay);
  }

  async send(command: Command): Promise<void> {
    const data = encode(command);
    if (!data) {
      throw new Error('command not supported by the light');
    }
    if (!this.connected) {
      await this.connect();
    }
    if (!this.command) {
      throw new Error('not connected');
    }
    const withoutResponse = !wantsResponse(command) && this.command.properties.includes('writeWithoutResponse');
    this.log.debug(`${this.label}: write ${data.toString('hex')}${withoutResponse ? '' : ' (with response)'}`);
    await this.command.writeAsync(data, withoutResponse);
  }

  async close(): Promise<void> {
    this.closed = true;
    if (this.reconnectTimer) {
      clearTimeout(this.reconnectTimer);
      this.reconnectTimer = undefined;
    }
    if (this.peripheral.state === 'connecting') {
      this.peripheral.cancelConnect();
      return;
    }
    try {
      await withTimeout(this.peripheral.disconnectAsync(), DISCONNECT_TIMEOUT_MS, 'disconnect');
    } catch {
      // ignore
    }
  }
}
