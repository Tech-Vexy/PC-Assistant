// Screen awareness: ScreenWatcher feed + Gemini multimodal describeScreen + screen_context tool.
// No real ffmpeg or network: frames and vision are injected via test seams.
import { describe, it, beforeEach } from 'node:test';
import assert from 'node:assert/strict';

describe('screen awareness', () => {
  let describeScreen;
  let screenWatcher;
  let __resetWatcher;
  let screenContext;
  let setOverrides;

  beforeEach(async () => {
    ({ describeScreen, screenWatcher, __resetWatcher } = await import('../lib/screen-watcher.js'));
    ({ screenContext, __setOverrides: setOverrides } = await import('../tools/screen-context.js'));
    __resetWatcher();
    setOverrides({});
  });

  const frame = (n, mime = 'image/jpeg') => ({ data: Buffer.from(`fake-jpeg-${n}`), ts: Date.now(), mime });

  it('describeScreen answers a question via the injected multimodal model', async () => {
    const calls = [];
    const vision = {
      ai: {
        models: {
          async generateContent({ model, contents }) {
            calls.push({ model, parts: contents[0].parts });
            return { text: 'Chrome is open with the profile picker; "Work" is highlighted.' };
          },
        },
      },
      model: 'gemini-test',
    };

    const r = await describeScreen('Which profile is selected?', {
      frames: [frame(1), frame(2), frame(3)],
      vision,
    });

    assert.equal(r.ok, true);
    assert.match(r.description, /Work/);
    assert.equal(r.frames, 3);
    // Multimodal: prompt + inline image parts reached the model.
    const parts = calls[0].parts;
    assert.match(parts[0].text, /Which profile is selected\?/);
    const images = parts.filter((p) => p.inlineData);
    assert.ok(images.length >= 1 && images.length <= 2, 'recent frames attached as inlineData');
    assert.equal(images[0].inlineData.mimeType, 'image/jpeg');
  });

  it('describeScreen reports a clear error when there are no frames', async () => {
    const r = await describeScreen('anything', { vision: { ai: { models: { generateContent: async () => ({ text: 'x' }) } }, model: 'm' } });
    assert.equal(r.ok, false);
    assert.match(r.error, /no frames/);
  });

  it('screen_context returns the description and watcher state', async () => {
    setOverrides({ describeScreen: async () => ({ ok: true, description: 'VS Code with tests open', frames: 2 }) });
    const r = await screenContext({ question: 'what is open?' });
    assert.equal(r.success, true);
    assert.equal(r.description, 'VS Code with tests open');
    assert.equal(r.frames, 2);
    assert.equal(r.watching, screenWatcher.running);
  });

  it('screen_context surfaces feed errors instead of inventing screen state', async () => {
    setOverrides({ describeScreen: async () => ({ ok: false, error: 'screen feed has no frames yet' }) });
    const r = await screenContext({});
    assert.equal(r.success, false);
    assert.match(r.error, /no frames/);
    assert.equal(r.watching, screenWatcher.running);
  });

  it('recentFrames thins a long window to first/middle/last', () => {
    screenWatcher.frames = Array.from({ length: 10 }, (_, i) => frame(i));
    const picked = screenWatcher.recentFrames(60_000, 3);
    assert.equal(picked.length, 3);
    assert.deepEqual(picked.map((f) => f.data.toString()), ['fake-jpeg-0', 'fake-jpeg-5', 'fake-jpeg-9']);
  });

  it('tool manifest includes screen_context as a read-only tool', async () => {
    process.env.AUTO_APPROVE = 'true';
    const { buildAllTools } = await import('../tools.js');
    const tools = buildAllTools();
    const def = tools.find((t) => t.name === 'screen_context');
    assert.ok(def, 'screen_context definition exists');
    assert.match(def.description, /screen/i);
    assert.ok(def.parameters.properties.question, 'question param exists');
  });

  it('computer_use accepts a context hint so the agent can chain look → act', async () => {
    const { buildAllTools } = await import('../tools.js');
    const def = buildAllTools().find((t) => t.name === 'computer_use');
    assert.ok(def, 'computer_use definition exists');
    const ctx = def.parameters.properties.context;
    assert.ok(ctx, 'context param exists on computer_use');
    assert.match(ctx.description, /screen_context/i);
  });
});
