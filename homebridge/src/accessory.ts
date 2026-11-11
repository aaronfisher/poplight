import type { CharacteristicValue, Logging, PlatformAccessory, Service } from 'homebridge';
import type { PoplightPlatform } from './platform';
import type { PoplightLink } from './ble';
import {
  WARMTH_MIREDS,
  clampBrightness,
  decodeStatus,
  warmthFromMireds,
  type Command,
  type Warmth,
} from './protocol';

/**
 * How long a HomeKit write waits for the light before it is acknowledged anyway. HomeKit shows
 * "No Response" after a few seconds, and an on-demand connection can take longer than that.
 */
const SET_GRACE_MS = 2_500;
/** On-demand: how long a connection made only to read the battery is kept. */
const BATTERY_HOLD_MS = 3_000;
const PENDING = Symbol('pending');

export interface PoplightContext {
  id: string;
  name: string;
  on?: boolean;
  brightness?: number;
  warmth?: Warmth;
  battery?: number;
}

/** One Poplight as a HomeKit lightbulb with a battery service. */
export class PoplightAccessory {
  private readonly light: Service;
  private readonly battery: Service;
  private readonly log: Logging;
  private pollTimer?: NodeJS.Timeout;
  private link?: PoplightLink;
  private querying = false;
  /** Called with the mapped battery percentage whenever the light reports it. */
  public onBattery?: (percent: number) => void;

  constructor(
    private readonly platform: PoplightPlatform,
    public readonly accessory: PlatformAccessory<PoplightContext>,
  ) {
    this.log = platform.log;
    const { Service, Characteristic } = platform.api.hap;
    const ctx = accessory.context;

    accessory
      .getService(Service.AccessoryInformation)!
      .setCharacteristic(Characteristic.Manufacturer, 'Poplight')
      .setCharacteristic(Characteristic.Model, 'Poplight sconce')
      .setCharacteristic(Characteristic.SerialNumber, ctx.id);

    this.light = accessory.getService(Service.Lightbulb) ?? accessory.addService(Service.Lightbulb);
    this.light.setCharacteristic(Characteristic.Name, ctx.name);
    this.light.getCharacteristic(Characteristic.On).onGet(() => ctx.on ?? false).onSet((v) => this.setOn(v));
    this.light
      .getCharacteristic(Characteristic.Brightness)
      .setProps({ minValue: 0, maxValue: 100, minStep: 1 })
      .onGet(() => ctx.brightness ?? 99)
      .onSet((v) => this.setBrightness(v));
    const colorTemperature = this.light.getCharacteristic(Characteristic.ColorTemperature);
    colorTemperature.setProps({ minValue: WARMTH_MIREDS.cool, maxValue: WARMTH_MIREDS.warm });
    // HAP's default (140 mireds) sits below our minimum; seed a legal value before HomeKit reads it.
    colorTemperature.updateValue(WARMTH_MIREDS[ctx.warmth ?? 'neutral']);
    colorTemperature.onGet(() => WARMTH_MIREDS[ctx.warmth ?? 'neutral']).onSet((v) => this.setColorTemperature(v));

    this.battery = accessory.getService(Service.Battery) ?? accessory.addService(Service.Battery);
    this.battery.getCharacteristic(Characteristic.BatteryLevel).onGet(() => ctx.battery ?? 100);
    this.battery
      .getCharacteristic(Characteristic.StatusLowBattery)
      .onGet(() =>
        (ctx.battery ?? 100) <= this.threshold
          ? Characteristic.StatusLowBattery.BATTERY_LEVEL_LOW
          : Characteristic.StatusLowBattery.BATTERY_LEVEL_NORMAL,
      );
    this.battery.setCharacteristic(Characteristic.ChargingState, Characteristic.ChargingState.NOT_CHARGEABLE);
  }

  get name(): string {
    return this.accessory.context.name;
  }

  private get threshold(): number {
    return this.platform.config.lowBatteryThreshold ?? 25;
  }

  rename(name: string): void {
    this.accessory.context.name = name;
    this.accessory.displayName = name;
    this.light.updateCharacteristic(this.hap.Characteristic.Name, name);
  }

  attach(link: PoplightLink): void {
    this.link = link;
    const onDemand = this.platform.onDemand;
    link.on('status', (data: Buffer) => this.handleStatus(data));
    link.on('connected', () => {
      if (!onDemand) {
        this.log.info(`${this.name}: ready`);
        this.startPolling();
      }
      // Connected anyway, so the battery reading is free.
      void this.refreshBattery();
    });
    link.on('disconnected', () => {
      if (!onDemand) {
        this.stopPolling();
      }
    });
    if (onDemand) {
      // The poll runs whether or not the link is up; each one is a short connection. The first
      // query doubles as the check that the light is reachable.
      this.startPolling();
      void this.refreshBattery(true);
    } else {
      void link.connect().catch(() => undefined);
    }
  }

  private get hap() {
    return this.platform.api.hap;
  }

  private fail(error: unknown): never {
    this.log.warn(`${this.name}: ${(error as Error).message}`);
    throw new this.hap.HapStatusError(this.hap.HAPStatus.SERVICE_COMMUNICATION_FAILURE);
  }

  /**
   * Send a command for a HomeKit write and record the new state once the light has it.
   *
   * With an on-demand link the light may first have to be connected, which can take longer than
   * HomeKit waits before showing "No Response". Past a short grace period the write is
   * acknowledged and finishes in the background; if it then fails, the tile is put back to the
   * last confirmed state.
   */
  private async deliver(command: Command, apply: () => void): Promise<void> {
    if (!this.link) {
      this.fail(new Error('not discovered yet'));
    }
    const ctx = this.accessory.context;
    const before = { on: ctx.on, brightness: ctx.brightness, warmth: ctx.warmth };
    const settled = this.link
      .send(command)
      .then(apply)
      .then(
        () => undefined,
        (error: unknown) => (error instanceof Error ? error : new Error(String(error))),
      );
    const grace = new Promise<typeof PENDING>((resolve) => setTimeout(() => resolve(PENDING), SET_GRACE_MS));
    const first = await Promise.race([settled, grace]);
    if (first === PENDING) {
      apply(); // show the requested state while the light is being reached
      void settled.then((error) => {
        if (error) {
          this.log.warn(`${this.name}: ${error.message}`);
          this.restore(before);
        }
      });
      return;
    }
    if (first) {
      this.fail(first);
    }
  }

  /** Put the cached state and the HomeKit tile back after a write that did not reach the light. */
  private restore(before: Pick<PoplightContext, 'on' | 'brightness' | 'warmth'>): void {
    const ctx = this.accessory.context;
    const { Characteristic } = this.hap;
    ctx.on = before.on;
    ctx.brightness = before.brightness;
    ctx.warmth = before.warmth;
    this.light.updateCharacteristic(Characteristic.On, before.on ?? false);
    this.light.updateCharacteristic(Characteristic.Brightness, before.brightness ?? 99);
    this.light.updateCharacteristic(Characteristic.ColorTemperature, WARMTH_MIREDS[before.warmth ?? 'neutral']);
  }

  private async setOn(value: CharacteristicValue): Promise<void> {
    const on = Boolean(value);
    const ctx = this.accessory.context;
    await this.deliver({ type: 'power', on }, () => {
      ctx.on = on;
    });
  }

  private async setBrightness(value: CharacteristicValue): Promise<void> {
    const ctx = this.accessory.context;
    const percent = Number(value);
    if (percent <= 0) {
      await this.deliver({ type: 'power', on: false }, () => {
        ctx.on = false;
      });
      return;
    }
    const clamped = clampBrightness(percent);
    await this.deliver({ type: 'brightness', value: clamped }, () => {
      ctx.brightness = clamped;
      ctx.on = true;
    });
  }

  private async setColorTemperature(value: CharacteristicValue): Promise<void> {
    const ctx = this.accessory.context;
    const warmth = warmthFromMireds(Number(value));
    await this.deliver({ type: 'warmth', warmth }, () => {
      ctx.warmth = warmth;
      // Snap HomeKit's slider to the step the light actually uses.
      this.light.updateCharacteristic(this.hap.Characteristic.ColorTemperature, WARMTH_MIREDS[warmth]);
    });
  }

  /** `retry`: keep trying to connect for a while (the startup check) instead of one attempt. */
  private async refreshBattery(retry = false): Promise<void> {
    if (this.querying) {
      return; // a poll that had to connect triggers the 'connected' handler too
    }
    this.querying = true;
    try {
      // On demand, a poll is a single short connection: one attempt, and let go right after.
      await this.link?.send(
        { type: 'queryStatus' },
        this.platform.onDemand ? { holdMs: BATTERY_HOLD_MS, retry } : {},
      );
    } catch (error) {
      this.log.debug(`${this.name}: battery query failed: ${(error as Error).message}`);
    } finally {
      this.querying = false;
    }
  }

  private handleStatus(data: Buffer): void {
    const status = decodeStatus(data);
    if (!status) {
      this.log.debug(`${this.name}: unknown status ${data.toString('hex')}`);
      return;
    }
    const ctx = this.accessory.context;
    const { Characteristic } = this.hap;
    // The light echoes accepted commands; treat them as confirmed state.
    if (status.on !== undefined) {
      ctx.on = status.on;
      this.light.updateCharacteristic(Characteristic.On, status.on);
    }
    if (status.brightness !== undefined) {
      ctx.brightness = status.brightness;
      ctx.on = true;
      this.light.updateCharacteristic(Characteristic.Brightness, status.brightness);
    }
    if (status.warmth !== undefined) {
      ctx.warmth = status.warmth;
      this.light.updateCharacteristic(Characteristic.ColorTemperature, WARMTH_MIREDS[status.warmth]);
    }
    if (status.batteryPercent === undefined) {
      return;
    }
    if (ctx.battery !== status.batteryPercent) {
      this.log.info(`${this.name}: battery ${status.batteryPercent}%`);
    }
    ctx.battery = status.batteryPercent;
    this.battery.updateCharacteristic(Characteristic.BatteryLevel, status.batteryPercent);
    this.battery.updateCharacteristic(
      Characteristic.StatusLowBattery,
      status.batteryPercent <= this.threshold
        ? Characteristic.StatusLowBattery.BATTERY_LEVEL_LOW
        : Characteristic.StatusLowBattery.BATTERY_LEVEL_NORMAL,
    );
    this.onBattery?.(status.batteryPercent);
  }

  private startPolling(): void {
    this.stopPolling();
    const minutes = this.platform.batteryPollMinutes;
    this.pollTimer = setInterval(() => void this.refreshBattery(), minutes * 60_000);
  }

  private stopPolling(): void {
    if (this.pollTimer) {
      clearInterval(this.pollTimer);
      this.pollTimer = undefined;
    }
  }
}
