#!/usr/bin/env node
/**
 * poplight-cli: drive a Poplight from the terminal using the same BLE code as the plugin.
 *
 *   poplight-cli scan                      list lights in range (10 s)
 *   poplight-cli [--id <id>] on|off
 *   poplight-cli [--id <id>] brightness 1..99
 *   poplight-cli [--id <id>] warmth warm|neutral|cool
 *   poplight-cli [--id <id>] timer <minutes>
 *   poplight-cli [--id <id>] battery
 *
 * Without --id the first light found is used.
 */
import noble from '@stoprocent/noble';
import type { Peripheral } from '@stoprocent/noble';
import { PoplightLink } from './ble';
import { decodeStatus, isPoplightName, type Command, type Warmth } from './protocol';

const log = {
  info: (m: string) => console.log(m),
  warn: (m: string) => console.warn(m),
  error: (m: string) => console.error(m),
  debug: (m: string) => process.env.DEBUG && console.log(`  ${m}`),
  log: (m: string) => console.log(m),
  success: (m: string) => console.log(m),
  prefix: 'poplight',
} as unknown as import('homebridge').Logging;

function usage(): never {
  console.error('usage: poplight-cli [--id <id>] scan | on | off | brightness <1-99> | warmth <warm|neutral|cool> | timer <minutes> | battery');
  process.exit(2);
}

async function findLight(id: string | undefined, timeoutMs: number): Promise<Peripheral> {
  await noble.waitForPoweredOnAsync();
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => {
      void noble.stopScanningAsync();
      reject(new Error('no Poplight found'));
    }, timeoutMs);
    noble.on('discover', (p: Peripheral) => {
      if (!isPoplightName(p.advertisement?.localName)) {
        return;
      }
      if (id && p.id.toLowerCase() !== id.toLowerCase()) {
        return;
      }
      clearTimeout(timer);
      void noble.stopScanningAsync();
      resolve(p);
    });
    void noble.stopScanningAsync().catch(() => undefined).then(() => noble.startScanningAsync([], true));
  });
}

async function scan(): Promise<void> {
  await noble.waitForPoweredOnAsync();
  const seen = new Set<string>();
  noble.on('discover', (p: Peripheral) => {
    if (isPoplightName(p.advertisement?.localName) && !seen.has(p.id)) {
      seen.add(p.id);
      console.log(`${p.id}  ${p.advertisement.localName}  ${p.rssi} dBm`);
    }
  });
  await noble.stopScanningAsync().catch(() => undefined);
  await noble.startScanningAsync([], true);
  await new Promise((r) => setTimeout(r, 10_000));
  await noble.stopScanningAsync();
  if (seen.size === 0) {
    console.log('no Poplight found (is it on, in range, and not connected to another app?)');
  }
}

async function main(): Promise<void> {
  const args = process.argv.slice(2);
  let id: string | undefined;
  const idIndex = args.indexOf('--id');
  if (idIndex >= 0) {
    id = args[idIndex + 1];
    args.splice(idIndex, 2);
  }
  const [verb, arg] = args;
  if (!verb) {
    usage();
  }
  if (verb === 'scan') {
    await scan();
    return;
  }

  let command: Command;
  switch (verb) {
    case 'on':
      command = { type: 'power', on: true };
      break;
    case 'off':
      command = { type: 'power', on: false };
      break;
    case 'brightness':
      command = { type: 'brightness', value: Number(arg) };
      break;
    case 'warmth':
      if (!['warm', 'neutral', 'cool'].includes(arg)) {
        usage();
      }
      command = { type: 'warmth', warmth: arg as Warmth };
      break;
    case 'timer':
      command = { type: 'sleepTimer', minutes: Number(arg) };
      break;
    case 'battery':
      command = { type: 'queryStatus' };
      break;
    default:
      usage();
  }

  const peripheral = await findLight(id, 15_000);
  console.log(`using ${peripheral.id} (${peripheral.advertisement.localName})`);
  const link = new PoplightLink(peripheral, log, 'light');
  await link.connect();

  const reply = new Promise<void>((resolve) => {
    if (command.type !== 'queryStatus') {
      resolve();
      return;
    }
    const timer = setTimeout(() => {
      console.log('no battery reply');
      resolve();
    }, 3_000);
    link.once('status', (data: Buffer) => {
      clearTimeout(timer);
      const status = decodeStatus(data);
      console.log(`battery ${status?.batteryPercent ?? '?'}% (raw ${data.toString('hex')})`);
      resolve();
    });
  });

  await link.send(command);
  await reply;
  await link.close();
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error((error as Error).message);
    process.exit(1);
  });
