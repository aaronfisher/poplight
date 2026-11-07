import { test } from 'node:test';
import assert from 'node:assert/strict';
import {
  batteryPercent,
  clampBrightness,
  decodeStatus,
  encode,
  isPoplightName,
  timerIndex,
  wantsResponse,
  warmthFromMireds,
  warmthFromWire,
} from './protocol';

test('power', () => {
  assert.deepEqual(encode({ type: 'power', on: true }), Buffer.from([1, 1, 1]));
  assert.deepEqual(encode({ type: 'power', on: false }), Buffer.from([1, 1, 0]));
});

test('brightness clamps to 1..99', () => {
  assert.deepEqual(encode({ type: 'brightness', value: 50 }), Buffer.from([1, 2, 50]));
  assert.deepEqual(encode({ type: 'brightness', value: 100 }), Buffer.from([1, 2, 99]));
  assert.deepEqual(encode({ type: 'brightness', value: 0 }), Buffer.from([1, 2, 1]));
  assert.equal(clampBrightness(42.6), 43);
});

test('warmth', () => {
  assert.deepEqual(encode({ type: 'warmth', warmth: 'cool' }), Buffer.from([1, 6, 0]));
  assert.deepEqual(encode({ type: 'warmth', warmth: 'neutral' }), Buffer.from([1, 6, 1]));
  assert.deepEqual(encode({ type: 'warmth', warmth: 'warm' }), Buffer.from([1, 6, 2]));
  assert.equal(warmthFromWire(2), 'warm');
  assert.equal(warmthFromWire(9), undefined);
  assert.equal(warmthFromMireds(140), 'cool');
  assert.equal(warmthFromMireds(260), 'neutral');
  assert.equal(warmthFromMireds(500), 'warm');
});

test('timer', () => {
  assert.deepEqual(encode({ type: 'sleepTimer', minutes: 30 }), Buffer.from([2, 3, 0, 2]));
  assert.deepEqual(encode({ type: 'sleepTimer', minutes: 60 }), Buffer.from([2, 3, 0, 4]));
  assert.equal(timerIndex(20), 1);
  assert.equal(timerIndex(2000), 48);
  assert.equal(encode({ type: 'sleepTimer', minutes: 0 }), undefined);
});

test('battery', () => {
  assert.deepEqual(encode({ type: 'queryStatus' }), Buffer.from([1, 9, 0]));
  assert.equal(wantsResponse({ type: 'queryStatus' }), true);
  assert.equal(wantsResponse({ type: 'power', on: true }), false);
  assert.deepEqual(decodeStatus(Buffer.from([1, 9, 80])), { batteryPercent: 100, batteryRaw: 80 });
  assert.equal(decodeStatus(Buffer.from([1, 9, 60]))?.batteryPercent, 75);
  assert.equal(decodeStatus(Buffer.from([1, 9, 73]))?.batteryPercent, 73);
  assert.equal(decodeStatus(Buffer.from([1, 2, 50])), undefined);
  assert.equal(decodeStatus(Buffer.from([1])), undefined);
  assert.equal(batteryPercent(20), 25);
});

test('name matching', () => {
  assert.equal(isPoplightName('POP_Light'), true);
  assert.equal(isPoplightName('POPLIGHT'), true);
  assert.equal(isPoplightName('Living room'), false);
  assert.equal(isPoplightName(undefined), false);
});
