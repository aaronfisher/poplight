import type { API, DynamicPlatformPlugin, Logging, PlatformAccessory, PlatformConfig } from 'homebridge';
import type { Peripheral } from '@stoprocent/noble';
import { PoplightAccessory, type PoplightContext } from './accessory';
import { PoplightLink, PoplightScanner, type BindingName } from './ble';
import { BatterySensorAccessory, type SensorContext } from './sensors';
import { PLATFORM_NAME, PLUGIN_NAME } from './settings';

export interface PoplightConfig extends PlatformConfig {
  autoDiscover?: boolean;
  batteryPollMinutes?: number;
  lowBatteryThreshold?: number;
  batterySensor?: boolean;
  lowBatterySensor?: boolean;
  bindings?: BindingName;
  lights?: { id: string; name: string }[];
}

type SensorKind = SensorContext['kind'];
const SENSOR_KINDS: SensorKind[] = ['battery', 'low'];

export class PoplightPlatform implements DynamicPlatformPlugin {
  public readonly config: PoplightConfig;
  private readonly accessories = new Map<string, PlatformAccessory<PoplightContext>>();
  private readonly handlers = new Map<string, PoplightAccessory>();
  private readonly links = new Map<string, PoplightLink>();
  private readonly sensorAccessories = new Map<string, PlatformAccessory<SensorContext>>(); // key: `${id}:${kind}`
  private readonly sensors = new Map<string, BatterySensorAccessory>();
  private scanner?: PoplightScanner;

  constructor(
    public readonly log: Logging,
    config: PlatformConfig,
    public readonly api: API,
  ) {
    this.config = config as PoplightConfig;
    api.on('didFinishLaunching', () => void this.start());
    api.on('shutdown', () => void this.shutdown());
  }

  /** Called by Homebridge for every accessory restored from cache, before didFinishLaunching. */
  configureAccessory(accessory: PlatformAccessory): void {
    const context = accessory.context as Partial<SensorContext>;
    if (context.kind === 'battery' || context.kind === 'low') {
      const typed = accessory as PlatformAccessory<SensorContext>;
      this.sensorAccessories.set(`${typed.context.id}:${typed.context.kind}`, typed);
      return; // handler is created (or the accessory dropped) once config is known, in start()
    }
    const typed = accessory as PlatformAccessory<PoplightContext>;
    this.log.info(`Restoring ${typed.context.name ?? accessory.displayName} from cache`);
    this.accessories.set(typed.context.id, typed);
    this.handlers.set(typed.context.id, new PoplightAccessory(this, typed));
  }

  private async start(): Promise<void> {
    // Reconcile cached companion sensors with the current config.
    for (const [key, accessory] of [...this.sensorAccessories]) {
      if (this.sensorEnabled(accessory.context.kind)) {
        this.sensors.set(key, new BatterySensorAccessory(this, accessory));
        this.log.info(`Restoring ${accessory.context.name} from cache`);
      } else {
        this.log.info(`Removing ${accessory.context.name} (disabled in config)`);
        this.api.unregisterPlatformAccessories(PLUGIN_NAME, PLATFORM_NAME, [accessory]);
        this.sensorAccessories.delete(key);
      }
    }
    for (const [id, handler] of this.handlers) {
      this.ensureSensors(id, handler);
    }

    this.scanner = new PoplightScanner(this.log, this.config.bindings ?? 'default');
    this.scanner.on('poplight', (peripheral: Peripheral) => this.handleDiscovered(peripheral));
    try {
      await this.scanner.start();
    } catch (error) {
      this.log.error(`Bluetooth unavailable: ${(error as Error).message}`);
    }
  }

  private sensorEnabled(kind: SensorKind): boolean {
    return kind === 'battery' ? this.config.batterySensor === true : this.config.lowBatterySensor === true;
  }

  private sensorName(lightName: string, kind: SensorKind): string {
    return kind === 'battery' ? `${lightName} Battery` : `${lightName} Battery Low`;
  }

  /** Create the enabled companion sensors for a light and wire battery updates to them. */
  private ensureSensors(id: string, handler: PoplightAccessory): void {
    for (const kind of SENSOR_KINDS) {
      if (!this.sensorEnabled(kind)) {
        continue;
      }
      const key = `${id}:${kind}`;
      if (!this.sensors.has(key)) {
        const name = this.sensorName(handler.name, kind);
        const uuid = this.api.hap.uuid.generate(`${PLUGIN_NAME}:${id}:${kind}`);
        const accessory = new this.api.platformAccessory<SensorContext>(name, uuid);
        accessory.context = { id, name, kind, battery: handler.accessory.context.battery };
        this.sensorAccessories.set(key, accessory);
        this.sensors.set(key, new BatterySensorAccessory(this, accessory));
        this.api.registerPlatformAccessories(PLUGIN_NAME, PLATFORM_NAME, [accessory]);
        this.log.info(`Added ${name}`);
      }
    }
    handler.onBattery = (percent) => {
      for (const kind of SENSOR_KINDS) {
        this.sensors.get(`${id}:${kind}`)?.update(percent);
      }
    };
  }

  private configuredName(id: string): string | undefined {
    return this.config.lights?.find((l) => l.id.toLowerCase() === id.toLowerCase())?.name;
  }

  private handleDiscovered(peripheral: Peripheral): void {
    const id = peripheral.id;
    const configured = this.configuredName(id);
    if (!configured && this.config.autoDiscover === false) {
      this.log.info(`Ignoring ${id}: not in config and auto-discover is off`);
      return;
    }

    const existingLink = this.links.get(id);
    if (existingLink) {
      // A known light heard again: nothing to do while connected; otherwise it is back after
      // going out of range or a battery swap, so reconnect to the fresh peripheral now.
      if (!existingLink.connected) {
        this.log.info(`${this.accessories.get(id)?.context.name ?? id}: back in range`);
        existingLink.replacePeripheral(peripheral);
      }
      return;
    }

    const name = configured ?? `Poplight ${id.replace(/[^a-z0-9]/gi, '').slice(-4).toUpperCase()}`;
    let accessory = this.accessories.get(id);
    if (!accessory) {
      const uuid = this.api.hap.uuid.generate(`${PLUGIN_NAME}:${id}`);
      accessory = new this.api.platformAccessory<PoplightContext>(name, uuid);
      accessory.context = { id, name };
      this.accessories.set(id, accessory);
      this.handlers.set(id, new PoplightAccessory(this, accessory));
      this.api.registerPlatformAccessories(PLUGIN_NAME, PLATFORM_NAME, [accessory]);
      this.log.info(`Added ${name} (${id})`);
    } else if (configured && accessory.context.name !== configured) {
      this.handlers.get(id)!.rename(configured);
      this.api.updatePlatformAccessories([accessory]);
      for (const kind of SENSOR_KINDS) {
        const sensor = this.sensors.get(`${id}:${kind}`);
        if (sensor) {
          sensor.rename(this.sensorName(configured, kind));
          this.api.updatePlatformAccessories([sensor.accessory]);
        }
      }
    }
    this.ensureSensors(id, this.handlers.get(id)!);

    this.log.info(`Found ${name} (${id}, ${peripheral.rssi} dBm)`);
    const link = new PoplightLink(peripheral, this.log, accessory.context.name);
    // noble stops scanning to connect and never resumes it, so keep the radio listening after
    // every connection event: for lights still to be found, and for this one if it drops.
    const resume = () => this.scanner?.ensureScanning();
    link.on('connected', resume);
    link.on('disconnected', resume);
    link.on('connectFailed', resume);
    this.links.set(id, link);
    this.handlers.get(id)!.attach(link);
  }

  private async shutdown(): Promise<void> {
    await Promise.all([...this.links.values()].map((l) => l.close()));
  }
}
