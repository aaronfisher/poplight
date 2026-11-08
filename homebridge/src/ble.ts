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
 * connection attempts from all links go through this queue.
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

/** Thin wrapper around noble: powers on, scans, and hands out Poplight peripherals. */
export class PoplightScanner extends EventEmitter {
  private started = false;
  private readonly seen = new Map<string, Peripheral>();
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
      if (!this.seen.has(peripheral.id)) {
        this.seen.set(peripheral.id, peripheral);
        this.log.info(`Found ${name} (${peripheral.id}, ${peripheral.rssi} dBm)`);
        this.emit('poplight', peripheral);
      }
    });
    noble.on('stateChange', (state: string) => {
      this.log.debug(`Bluetooth state: ${state}`);
      if (state === 'poweredOn') {
        void this.scan();
      }
    });
    // The HCI binding turns scanning off to establish a connection and never turns it back on,
    // so a second light would stay undiscovered. Resume once all pending attempts have settled.
    onConnectQueueIdle = () => void this.scan();
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

  async scan(): Promise<void> {
    try {
      // A previous process may have left the adapter scanning; the HCI binding then fails to
      // set scan parameters with EIO. Clearing first makes start reliable on Linux.
      await this.noble.stopScanningAsync().catch(() => undefined);
      // allowDuplicates: the name only travels in the scan response. With duplicates filtered,
      // noble reports a peripheral once, and if that report happened to be built from two bare
      // ADV_IND packets (scan response lost) the light stays nameless and invisible for the rest
      // of the session. Every report is cheap to filter here, so take them all.
      await this.noble.startScanningAsync([], true);
      this.log.debug('Scanning for POP_Light');
    } catch (error) {
      this.log.warn(`Scan failed: ${errorMessage(error)}`);
    }
  }

  /** Forget a peripheral so the next advertisement re-emits it (used after repeated connect failures). */
  async rescan(id: string): Promise<void> {
    this.seen.delete(id);
    try {
      await this.noble.stopScanningAsync();
    } catch {
      // ignore
    }
    await this.scan();
  }
}

export interface LinkEvents {
  connected: () => void;
  disconnected: (reason?: string) => void;
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
    private readonly hciSocket: boolean = usesHciSocket('default'),
  ) {
    super();
  }

  /** Replace the peripheral object after a rescan (noble may hand out a new instance). */
  replacePeripheral(peripheral: Peripheral): void {
    this.peripheral = peripheral;
    this.attempts = 0;
    void this.connect();
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
    try {
      await serializedConnect(async () => {
        if (this.closed) {
          throw new Error('link closed');
        }
        this.log.debug(`${this.label}: connecting (attempt ${this.attempts + 1})`);
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
          this.log.debug(`${this.label}: enabling FFB2 notifications`);
          await withTimeout(this.enableNotifications(this.status), SUBSCRIBE_TIMEOUT_MS, 'notification setup');
        }
      });
      p.removeAllListeners('disconnect');
      p.once('disconnect', (reason?: string) => this.handleDisconnect(reason));
      this.connected = true;
      this.attempts = 0;
      this.log.info(`${this.label}: connected`);
      this.emit('connected');
    } catch (error) {
      this.attempts += 1;
      this.connected = false;
      this.log.warn(`${this.label}: connect failed: ${errorMessage(error)}`);
      // noble never resolves a disconnect for a link that was not fully established, so do not
      // let this await pin the link in "connecting" forever.
      await withTimeout(p.disconnectAsync(), DISCONNECT_TIMEOUT_MS, 'disconnect').catch(() => undefined);
      this.scheduleReconnect();
      throw error;
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
      if (this.attempts >= 4) {
        this.emit('stale');
      }
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
    await withTimeout(this.peripheral.disconnectAsync(), DISCONNECT_TIMEOUT_MS, 'disconnect').catch(() => undefined);
  }
}
