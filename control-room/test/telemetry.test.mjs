import test from 'node:test';
import assert from 'node:assert/strict';
import { resolutionLabel, rokuOSLabel } from '../web/telemetry.mjs';

test('resolution labels reflect reported source dimensions', () => {
  for (const [width, height, expected] of [
    [1280, 720, '720p'], [1920, 1080, '1080p'], [2560, 1440, '2K'],
    [3840, 2160, '4K'], [4096, 2160, '4K'], [720, 480, '480p'],
    [640, 360, '360p'], [1920, 800, '800p'],
  ]) assert.equal(resolutionLabel(width, height), expected);
  for (const [width, height] of [[null, null], [1920, null], [0, 1080], ['1920', '1080'], [1920, NaN], [1920, Infinity], [1920.5, 1080], [99999, 1080]]) {
    assert.equal(resolutionLabel(width, height), '—');
  }
});

test('legacy placeholder OS version is hidden until a new Roku report arrives', () => {
  assert.equal(rokuOSLabel('999.99E99999A'), '—');
  assert.equal(rokuOSLabel(null), '—');
  assert.equal(rokuOSLabel('15.3.4 (build 2303)'), '15.3.4 (build 2303)');
});
