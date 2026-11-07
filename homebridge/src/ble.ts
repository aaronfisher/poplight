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
    this.log.info('Waiting for Bluetooth…');
    await noble.waitForPoweredOnAsync();
    await this.scan();
  }

  async scan(): Promise<void> {
    try {
      // A previous process may have left the adapter scanning; the HCI binding then fails to
      // set scan parameters with EIO. Clearing first makes start reliable on Linux.
      await this.noble.stopScanningAsync().catch(() => undefined);
      await this.noble.startScanningAsync([], false);
      this.log.debug('Scanning for POP_Light');
    } catch (error) {
      this.log.warn(`Scan failed: ${(error as Error).message}`);
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
      this.log.info(`${this.label}: connected`);
      this.emit('connected');
    } catch (error) {
      this.attempts += 1;
      this.connected = false;
      this.log.warn(`${this.label}: connect failed: ${(error as Error).message}`);
      try {
        await p.disconnectAsync();
      } catch {
        // ignore
      }
      this.scheduleReconnect();
      throw error;
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
    try {
      await this.peripheral.disconnectAsync();
    } catch {
      // ignore
    }
  }
}
