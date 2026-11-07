import type { API, DynamicPlatformPlugin, Logging, PlatformAccessory, PlatformConfig } from 'homebridge';
import type { Peripheral } from '@stoprocent/noble';
import { PoplightAccessory, type PoplightContext } from './accessory';
import { PoplightLink, PoplightScanner } from './ble';
import { PLATFORM_NAME, PLUGIN_NAME } from './settings';

export interface PoplightConfig extends PlatformConfig {
  autoDiscover?: boolean;
  batteryPollMinutes?: number;
  lights?: { id: string; name: string }[];
}

export class PoplightPlatform implements DynamicPlatformPlugin {
  public readonly config: PoplightConfig;
  private readonly accessories = new Map<string, PlatformAccessory<PoplightContext>>();
  private readonly handlers = new Map<string, PoplightAccessory>();
  private readonly links = new Map<string, PoplightLink>();
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
    const typed = accessory as PlatformAccessory<PoplightContext>;
    this.log.info(`Restoring ${typed.context.name ?? accessory.displayName} from cache`);
    this.accessories.set(typed.context.id, typed);
    this.handlers.set(typed.context.id, new PoplightAccessory(this, typed));
  }

  private async start(): Promise<void> {
    this.scanner = new PoplightScanner(this.log);
    this.scanner.on('poplight', (peripheral: Peripheral) => this.handleDiscovered(peripheral));
    try {
      await this.scanner.start();
    } catch (error) {
      this.log.error(`Bluetooth unavailable: ${(error as Error).message}`);
    }
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
      existingLink.replacePeripheral(peripheral);
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
      accessory.context.name = configured;
      accessory.displayName = configured;
      this.api.updatePlatformAccessories([accessory]);
    }

    const link = new PoplightLink(peripheral, this.log, accessory.context.name);
    link.on('stale', () => void this.scanner?.rescan(id));
    this.links.set(id, link);
    this.handlers.get(id)!.attach(link);
  }

  private async shutdown(): Promise<void> {
    await Promise.all([...this.links.values()].map((l) => l.close()));
  }
}
