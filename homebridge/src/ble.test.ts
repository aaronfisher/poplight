import assert from 'node:assert/strict';
import { EventEmitter } from 'node:events';
import { test } from 'node:test';
import type { Logging } from 'homebridge';
import type { Peripheral } from '@stoprocent/noble';
import { PoplightLink } from './ble';
import { COMMAND_CHARACTERISTIC_UUID, STATUS_CHARACTERISTIC_UUID } from './protocol';

const log = {
  info: () => undefined,
  warn: () => undefined,
  error: () => undefined,
  debug: () => undefined,
} as unknown as Logging;

const wait = (ms: number) => new Promise((resolve) => setTimeout(resolve, ms));

/** Just enough of a noble Peripheral for PoplightLink. */
class FakePeripheral extends EventEmitter {
  id = 'aabbccddeeff';
  state = 'disconnected';
  connects = 0;
  disconnects = 0;
  writes: Buffer[] = [];
  /** Number of upcoming connect attempts that should fail. */
  failConnects = 0;
  private writeDone?: () => void;

  async connectAsync(): Promise<void> {
    this.connects += 1;
    if (this.failConnects > 0) {
      this.failConnects -= 1;
      this.state = 'error';
      throw new Error('Disconnected 62');
    }
    this.state = 'connected';
  }

  async discoverSomeServicesAndCharacteristicsAsync() {
    const command = {
      uuid: COMMAND_CHARACTERISTIC_UUID,
      properties: ['write', 'writeWithoutResponse'],
      // Like noble: one completion slot per characteristic. A write issued while another is
      // pending takes the slot over, and the earlier promise never settles.
      writeAsync: (data: Buffer) => {
        this.writes.push(data);
        return new Promise<void>((resolve) => {
          this.writeDone = resolve;
          setTimeout(() => this.writeDone?.(), 2);
        });
      },
    };
    const status = Object.assign(new EventEmitter(), {
      uuid: STATUS_CHARACTERISTIC_UUID,
      properties: ['notify'],
      subscribeAsync: async () => undefined,
    });
    return { services: [], characteristics: [command, status] };
  }

  async disconnectAsync(): Promise<void> {
    this.disconnects += 1;
    this.state = 'disconnected';
    this.emit('disconnect', 'local');
  }

  cancelConnect(): void {
    this.state = 'disconnected';
  }
}

function makeLink(options: { persistent: boolean; idleMs?: number }) {
  const peripheral = new FakePeripheral();
  const link = new PoplightLink(peripheral as unknown as Peripheral, log, 'test', {
    hciSocket: false,
    ...options,
  });
  return { peripheral, link };
}

test('on demand: connects for a command and disconnects when idle', async () => {
  const { peripheral, link } = makeLink({ persistent: false, idleMs: 40 });
  assert.equal(peripheral.connects, 0, 'nothing happens until a command is sent');

  await link.send({ type: 'power', on: true });
  assert.equal(peripheral.connects, 1);
  assert.equal(peripheral.writes.length, 1);
  assert.equal(link.connected, true);

  await wait(120);
  assert.equal(peripheral.disconnects, 1, 'idle link is released');
  assert.equal(link.connected, false);

  await link.send({ type: 'power', on: false });
  assert.equal(peripheral.connects, 2, 'next command reconnects');
  assert.equal(peripheral.writes.length, 2);
  await link.close();
});

test('on demand: commands in quick succession share one connection and extend the idle window', async () => {
  const { peripheral, link } = makeLink({ persistent: false, idleMs: 80 });
  await Promise.all([link.send({ type: 'power', on: true }), link.send({ type: 'brightness', value: 50 })]);
  assert.equal(peripheral.connects, 1);
  assert.equal(peripheral.writes.length, 2);

  await wait(50);
  await link.send({ type: 'brightness', value: 60 });
  await wait(50);
  assert.equal(peripheral.disconnects, 0, 'still inside the window restarted by the last command');
  await wait(100);
  assert.equal(peripheral.disconnects, 1);
  await link.close();
});

test('overlapping commands all complete (noble keeps one completion slot per characteristic)', async () => {
  const { peripheral, link } = makeLink({ persistent: false, idleMs: 40 });
  // What the accessory does: a battery query fired from the 'connected' event, on top of the
  // command that caused the connection.
  let query: Promise<void> | undefined;
  link.on('connected', () => {
    query = link.send({ type: 'queryStatus' }, { holdMs: 10, retry: false });
  });
  await Promise.all([link.send({ type: 'power', on: true }), link.send({ type: 'brightness', value: 40 })]);
  await query;
  assert.equal(peripheral.writes.length, 3);
  await wait(120);
  assert.equal(peripheral.disconnects, 1, 'nothing left in flight, so the idle link is released');
  await link.close();
});

test('on demand: a shorter hold does not cut an existing idle window short', async () => {
  const { peripheral, link } = makeLink({ persistent: false, idleMs: 150 });
  await link.send({ type: 'power', on: true });
  await link.send({ type: 'queryStatus' }, { holdMs: 10 });
  await wait(60);
  assert.equal(peripheral.disconnects, 0);
  await link.close();
});

test('on demand: retries a failed connection while a command is waiting', async () => {
  const { peripheral, link } = makeLink({ persistent: false, idleMs: 40 });
  peripheral.failConnects = 1;
  await link.send({ type: 'power', on: true });
  assert.equal(peripheral.connects, 2);
  assert.equal(peripheral.writes.length, 1);
  await link.close();
});

test('on demand: retry off fails after a single attempt', async () => {
  const { peripheral, link } = makeLink({ persistent: false, idleMs: 40 });
  peripheral.failConnects = 1;
  await assert.rejects(link.send({ type: 'queryStatus' }, { retry: false }), /Disconnected 62/);
  assert.equal(peripheral.connects, 1);
  await link.close();
});

test('on demand: a dropped link stays down until the next command', async () => {
  const { peripheral, link } = makeLink({ persistent: false, idleMs: 5_000 });
  await link.send({ type: 'power', on: true });
  peripheral.state = 'disconnected';
  peripheral.emit('disconnect', '8');
  assert.equal(link.connected, false);
  await wait(50);
  assert.equal(peripheral.connects, 1, 'no background reconnect');
  await link.send({ type: 'power', on: false });
  assert.equal(peripheral.connects, 2);
  await link.close();
});

test('a connection that completes after its attempt failed is dropped when nobody is waiting', async () => {
  const { peripheral, link } = makeLink({ persistent: false, idleMs: 40 });
  peripheral.failConnects = 1;
  await assert.rejects(link.send({ type: 'queryStatus' }, { retry: false }));
  // The kernel finishes the connection on its own; noble marks the peripheral connected.
  peripheral.state = 'connected';
  peripheral.emit('connect');
  await wait(10);
  assert.equal(peripheral.disconnects, 1);
  assert.equal(peripheral.state, 'disconnected');
  await link.close();
});

test('a link noble already holds is adopted instead of failing with "already connected"', async () => {
  const { peripheral, link } = makeLink({ persistent: false, idleMs: 40 });
  peripheral.state = 'connected';
  await link.send({ type: 'power', on: true });
  assert.equal(peripheral.connects, 0, 'no second connection request');
  assert.equal(peripheral.writes.length, 1);
  await link.close();
});

test('persistent: stays connected when idle', async () => {
  const { peripheral, link } = makeLink({ persistent: true, idleMs: 20 });
  await link.send({ type: 'power', on: true });
  await wait(80);
  assert.equal(peripheral.disconnects, 0);
  assert.equal(link.connected, true);
  await link.close();
});
