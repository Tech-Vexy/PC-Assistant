// Device context tests (pure unit — no real app discovery, no store).
import { describe, it } from 'node:test';
import assert from 'node:assert/strict';

import { gatherDeviceContext, formatDeviceContext } from '../lib/device-context.js';

describe('gatherDeviceContext', () => {
  it('maps tool output (applications[].name) into a compact app list', async () => {
    const ctx = await gatherDeviceContext({
      listInstalledApps: async () => ({
        applications: [
          { name: ' Spotify ' },
          { name: 'Spotify' }, // duplicate is kept here; dedupe happens in format
          { name: '' }, // dropped
          null, // dropped
          { name: 42 }, // dropped
        ],
      }),
    });
    assert.equal(ctx.apps.length, 2);
    assert.deepEqual(ctx.apps.map((a) => a.name), ['Spotify', 'Spotify']);
    assert.equal(ctx.error, undefined);
  });

  it('records discovery errors instead of throwing', async () => {
    const ctx = await gatherDeviceContext({
      listInstalledApps: async () => {
        throw new Error('powershell exploded');
      },
    });
    assert.match(ctx.error, /powershell exploded/);
    // On Windows the common-apps fallback still provides a launch vocabulary;
    // elsewhere apps stays empty.
    if (process.platform !== 'win32') {
      assert.deepEqual(ctx.apps, []);
    }
  });

  it('falls back to common system apps on Windows when discovery is empty', async () => {
    const ctx = await gatherDeviceContext({
      listInstalledApps: async () => ({ applications: [] }),
    });
    // Only applies on win32; on other platforms apps stays empty.
    if (process.platform === 'win32') {
      assert.ok(ctx.apps.length > 0);
      assert.equal(ctx.fallback, 'common-system-apps');
      assert.ok(ctx.apps.some((a) => a.name === 'Control Panel'));
    } else {
      assert.deepEqual(ctx.apps, []);
    }
  });
});

describe('formatDeviceContext', () => {
  it('returns an empty string when there are no apps', () => {
    assert.equal(formatDeviceContext(null), '');
    assert.equal(
      formatDeviceContext({ os: { platform: 'win32', release: '1', arch: 'x64', hostname: 'h', username: 'u' }, apps: [] }),
      ''
    );
  });

  it('renders OS line, alphabetized deduped apps, and launches guidance', () => {
    const text = formatDeviceContext({
      os: { platform: 'win32', release: '10.0.26100', arch: 'x64', hostname: 'DESK', username: 'Veldrine' },
      apps: [{ name: 'Firefox' }, { name: 'Audacity' }, { name: 'Audacity' }],
    });
    assert.match(text, /OS: win32 \(10\.0\.26100, x64\); user Veldrine on DESK\./);
    assert.match(text, /- Audacity/);
    assert.match(text, /- Firefox/);
    assert.match(text, /open_application/);
    const audacityCount = (text.match(/- Audacity/g) || []).length;
    assert.equal(audacityCount, 1, 'duplicate apps should be deduped');
    const idxAudacity = text.indexOf('- Audacity');
    const idxFirefox = text.indexOf('- Firefox');
    assert.ok(idxAudacity < idxFirefox, 'apps should be alphabetized');
  });

  it('caps the number of apps and mentions the remainder', () => {
    const apps = Array.from({ length: 10 }, (_, i) => ({ name: `App ${String(i).padStart(2, '0')}` }));
    const text = formatDeviceContext(
      { os: { platform: 'linux', release: '6', arch: 'x64', hostname: 'h', username: 'u' }, apps },
      { maxApps: 3 }
    );
    assert.match(text, /and 7 more/);
    assert.doesNotMatch(text, /- App 09/);
  });

  it('appends a note when discovery fell back to the common list', () => {
    const text = formatDeviceContext({
      os: { platform: 'win32', release: '1', arch: 'x64', hostname: 'h', username: 'u' },
      apps: [{ name: 'Notepad' }],
      fallback: 'common-system-apps',
    });
    assert.match(text, /common built-in app list/);
  });

  it('appends a note when discovery errored', () => {
    const text = formatDeviceContext({
      os: { platform: 'win32', release: '1', arch: 'x64', hostname: 'h', username: 'u' },
      apps: [{ name: 'Notepad' }],
      error: 'boom',
    });
    assert.match(text, /discovery failed at publish time \(boom\)/);
  });
});
