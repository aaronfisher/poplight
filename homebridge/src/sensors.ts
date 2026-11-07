import type { PlatformAccessory, Service } from 'homebridge';
import type { PoplightPlatform } from './platform';

export interface SensorContext {
  id: string;
  name: string;
  kind: 'battery' | 'low';
  battery?: number;
}

/**
 * Optional companion accessories so the battery is visible without opening the light:
 * - 'battery': a humidity sensor whose value is the battery percentage (shows "75%" on the tile)
 * - 'low': a contact sensor that "opens" when the battery hits the threshold (Home can notify on it)
 */
export class BatterySensorAccessory {
  private readonly service: Service;

  constructor(
    private readonly platform: PoplightPlatform,
    public readonly accessory: PlatformAccessory<SensorContext>,
  ) {
    const { Service, Characteristic } = platform.api.hap;
    const ctx = accessory.context;

    accessory
      .getService(Service.AccessoryInformation)!
      .setCharacteristic(Characteristic.Manufacturer, 'Poplight')
      .setCharacteristic(Characteristic.Model, ctx.kind === 'battery' ? 'Poplight battery level' : 'Poplight low battery')
      .setCharacteristic(Characteristic.SerialNumber, `${ctx.id}-${ctx.kind}`);

    if (ctx.kind === 'battery') {
      this.service = accessory.getService(Service.HumiditySensor) ?? accessory.addService(Service.HumiditySensor);
      this.service.getCharacteristic(Characteristic.CurrentRelativeHumidity).onGet(() => ctx.battery ?? 100);
    } else {
      this.service = accessory.getService(Service.ContactSensor) ?? accessory.addService(Service.ContactSensor);
      this.service.getCharacteristic(Characteristic.ContactSensorState).onGet(() => this.contactState(ctx.battery));
    }
    this.service.setCharacteristic(Characteristic.Name, ctx.name);
    this.service
      .getCharacteristic(Characteristic.StatusLowBattery)
      .onGet(() => this.lowBattery(ctx.battery));
  }

  private get threshold(): number {
    return this.platform.config.lowBatteryThreshold ?? 25;
  }

  private contactState(battery: number | undefined): number {
    const { ContactSensorState } = this.platform.api.hap.Characteristic;
    return battery !== undefined && battery <= this.threshold
      ? ContactSensorState.CONTACT_NOT_DETECTED
      : ContactSensorState.CONTACT_DETECTED;
  }

  private lowBattery(battery: number | undefined): number {
    const { StatusLowBattery } = this.platform.api.hap.Characteristic;
    return battery !== undefined && battery <= this.threshold
      ? StatusLowBattery.BATTERY_LEVEL_LOW
      : StatusLowBattery.BATTERY_LEVEL_NORMAL;
  }

  update(battery: number): void {
    const ctx = this.accessory.context;
    ctx.battery = battery;
    const { Characteristic } = this.platform.api.hap;
    if (ctx.kind === 'battery') {
      this.service.updateCharacteristic(Characteristic.CurrentRelativeHumidity, battery);
    } else {
      this.service.updateCharacteristic(Characteristic.ContactSensorState, this.contactState(battery));
    }
    this.service.updateCharacteristic(Characteristic.StatusLowBattery, this.lowBattery(battery));
  }

  rename(name: string): void {
    this.accessory.context.name = name;
    this.accessory.displayName = name;
    this.service.updateCharacteristic(this.platform.api.hap.Characteristic.Name, name);
  }
}
