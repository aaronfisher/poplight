import type { CharacteristicValue, Logging, PlatformAccessory, Service } from 'homebridge';
import type { PoplightPlatform } from './platform';
import type { PoplightLink } from './ble';
import {
  WARMTH_MIREDS,
  clampBrightness,
  decodeStatus,
  warmthFromMireds,
  type Warmth,
} from './protocol';

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
    link.on('status', (data: Buffer) => this.handleStatus(data));
    link.on('connected', () => {
      this.log.info(`${this.name}: ready`);
      this.startPolling();
      void this.refreshBattery();
    });
    link.on('disconnected', () => this.stopPolling());
    void link.connect().catch(() => undefined);
  }

  private get hap() {
    return this.platform.api.hap;
  }

  private fail(error: unknown): never {
    this.log.warn(`${this.name}: ${(error as Error).message}`);
    throw new this.hap.HapStatusError(this.hap.HAPStatus.SERVICE_COMMUNICATION_FAILURE);
  }

  private async setOn(value: CharacteristicValue): Promise<void> {
    const on = Boolean(value);
    const ctx = this.accessory.context;
    if (!this.link) {
      this.fail(new Error('not discovered yet'));
    }
    try {
      await this.link.send({ type: 'power', on });
      ctx.on = on;
    } catch (error) {
      this.fail(error);
    }
  }

  private async setBrightness(value: CharacteristicValue): Promise<void> {
    const ctx = this.accessory.context;
    const percent = Number(value);
    if (!this.link) {
      this.fail(new Error('not discovered yet'));
    }
    try {
      if (percent <= 0) {
        await this.link.send({ type: 'power', on: false });
        ctx.on = false;
        return;
      }
      const clamped = clampBrightness(percent);
      await this.link.send({ type: 'brightness', value: clamped });
      ctx.brightness = clamped;
      ctx.on = true;
    } catch (error) {
      this.fail(error);
    }
  }

  private async setColorTemperature(value: CharacteristicValue): Promise<void> {
    const ctx = this.accessory.context;
    const warmth = warmthFromMireds(Number(value));
    if (!this.link) {
      this.fail(new Error('not discovered yet'));
    }
    try {
      await this.link.send({ type: 'warmth', warmth });
      ctx.warmth = warmth;
      // Snap HomeKit's slider to the step the light actually uses.
      this.light.updateCharacteristic(this.hap.Characteristic.ColorTemperature, WARMTH_MIREDS[warmth]);
    } catch (error) {
      this.fail(error);
    }
  }

  private async refreshBattery(): Promise<void> {
    try {
      await this.link?.send({ type: 'queryStatus' });
    } catch (error) {
      this.log.debug(`${this.name}: battery query failed: ${(error as Error).message}`);
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
    const minutes = this.platform.config.batteryPollMinutes ?? 5;
    this.pollTimer = setInterval(() => void this.refreshBattery(), minutes * 60_000);
  }

  private stopPolling(): void {
    if (this.pollTimer) {
      clearInterval(this.pollTimer);
      this.pollTimer = undefined;
    }
  }
}
