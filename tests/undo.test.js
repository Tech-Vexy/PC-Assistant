// Undo/transaction layer: journaling through the real dispatcher +
// applyRecord/undo_last/undo_session/list_undo round-trips. Isolated DuckDB
// store and temp workspace root so no real files or the real DB are touched.
process.env.AUTO_APPROVE = 'true';
process.env.MCP_ENABLED = 'false';

import os from 'node:os';
import path from 'node:path';
import fsSync from 'node:fs';
import fs from 'node:fs/promises';

const TMP = fsSync.mkdtempSync(path.join(os.tmpdir(), 'undo-test-'));
process.env.STORE_PATH = path.join(TMP, 'store.db');
process.env.WORKSPACE_ROOT = TMP;
process.env.ALLOWED_DIRS = TMP;

import { describe, it, before, after } from 'node:test';
import assert from 'node:assert/strict';

describe('undo / transaction layer', () => {
  before(async () => {
    const { initStore } = await import('../lib/store.js');
    await initStore();
  });

  after(async () => {
    const { closeStore } = await import('../lib/store.js');
    await closeStore();
    await fs.rm(TMP, { recursive: true, force: true }).catch(() => {});
  });

  it('journals file_organize and undo restores the original layout', async () => {
    const dir = path.join(TMP, 'organize');
    await fs.mkdir(dir, { recursive: true });
    await fs.writeFile(path.join(dir, 'a.png'), 'png-bytes');
    await fs.writeFile(path.join(dir, 'b.txt'), 'txt-bytes');

    const { dispatchTool } = await import('../tools.js');
    const run = await dispatchTool('file_organize', { folderPath: dir });
    assert.equal(run.success, true);
    assert.equal(run.moved, 2);
    assert.ok(await statExists(path.join(dir, 'Images', 'a.png')));
    assert.ok(await statExists(path.join(dir, 'Documents', 'b.txt')));

    const undo = await dispatchTool('undo_last', {});
    assert.equal(undo.success, true, `undo failed: ${undo.message || ''}`);
    assert.ok(await statExists(path.join(dir, 'a.png')), 'a.png back at top level');
    assert.ok(await statExists(path.join(dir, 'b.txt')), 'b.txt back at top level');
    assert.ok(!(await statExists(path.join(dir, 'Images'))), 'created category dir removed');
    assert.ok(!(await statExists(path.join(dir, 'Documents'))), 'created category dir removed');
  });

  it('file_organize undo restores a destination file that was overwritten', async () => {
    const dir = path.join(TMP, 'organize-overwrite');
    await fs.mkdir(path.join(dir, 'Images'), { recursive: true });
    // Pre-existing file that will be overwritten by the incoming same-named file
    await fs.writeFile(path.join(dir, 'Images', 'dup.png'), 'original-content');
    // Incoming file that will clobber it
    await fs.writeFile(path.join(dir, 'dup.png'), 'new-content');

    const { dispatchTool } = await import('../tools.js');
    const run = await dispatchTool('file_organize', { folderPath: dir });
    assert.equal(run.moved, 1);
    assert.equal(await fs.readFile(path.join(dir, 'Images', 'dup.png'), 'utf8'), 'new-content');

    const undo = await dispatchTool('undo_last', {});
    assert.equal(undo.success, true, `undo failed: ${undo.message || ''}`);
    assert.equal(
      await fs.readFile(path.join(dir, 'Images', 'dup.png'), 'utf8'),
      'original-content',
      'overwritten destination content restored'
    );
    assert.equal(await fs.readFile(path.join(dir, 'dup.png'), 'utf8'), 'new-content');
  });

  it('undo_last restores a forgotten memory with its category', async () => {
    const { dispatchTool } = await import('../tools.js');
    await dispatchTool('remember', { key: 'undo-pref', value: 'dark mode', category: 'preference' });
    const gone = await dispatchTool('forget', { key: 'undo-pref' });
    assert.equal(gone.success, true);

    const undo = await dispatchTool('undo_last', {});
    assert.equal(undo.success, true, `undo failed: ${undo.message || ''}`);

    const { memGetFull } = await import('../lib/store.js');
    const restored = await memGetFull('undo-pref');
    assert.deepEqual(restored, { value: 'dark mode', category: 'preference' });

    // Redo path: undo again should now remove what the undo restored
    const undo2 = await dispatchTool('undo_last', {});
    assert.equal(undo2.success, true);
    const goneAgain = await memGetFull('undo-pref');
    assert.equal(goneAgain, null);
  });

  it('workflow overwrite is undoable back to the previous steps', async () => {
    const { dispatchTool } = await import('../tools.js');
    await dispatchTool('save_workflow', { name: 'undo-wf', steps: [{ tool: 'system_status', args: {} }], description: 'v1' });
    await dispatchTool('save_workflow', { name: 'undo-wf', steps: [{ tool: 'list_processes', args: {} }], description: 'v2' });

    const undo = await dispatchTool('undo_last', {});
    assert.equal(undo.success, true, `undo failed: ${undo.message || ''}`);

    const { wfGet } = await import('../lib/store.js');
    const restored = await wfGet('undo-wf');
    assert.equal(restored.description, 'v1');
    assert.equal(restored.steps[0].tool, 'system_status');
  });

  it('manual-reversibility actions are journaled but never auto-applied', async () => {
    const { dispatchTool } = await import('../tools.js');
    // system_status is not journalable; use a real run_command (AUTO_APPROVE=true)
    const run = await dispatchTool('run_command', { command: process.platform === 'win32' ? 'whoami' : 'true' });
    assert.ok(!run.error, `run_command failed unexpectedly: ${run.error}`);

    const list = await dispatchTool('list_undo', { pendingOnly: true, limit: 50 });
    const cmd = list.actions.find((a) => a.tool === 'run_command');
    assert.ok(cmd, 'run_command journaled');
    assert.equal(cmd.reversibility, 'manual');

    const undo = await dispatchTool('undo_last', {});
    assert.equal(undo.success, false, 'manual record must not auto-apply');
    assert.match(undo.message, /no automatic reversal|manual/);
  });

  it('undo_session reverses every automatic action from a session', async () => {
    const { dispatchTool } = await import('../tools.js');
    process.env.AGENT_SESSION_ID = 'sess-undo-test';

    const dir = path.join(TMP, 'session');
    await fs.mkdir(dir, { recursive: true });
    await fs.writeFile(path.join(dir, 'x.jpg'), 'img');
    await fs.writeFile(path.join(dir, 'y.md'), 'doc');
    await dispatchTool('remember', { key: 'sess-mem', value: 'v1', category: 'fact' });

    await dispatchTool('file_organize', { folderPath: dir });
    await dispatchTool('forget', { key: 'sess-mem' });

    // Three journal rows for this session: remember, organize, forget.
    // Rolling the session back restores the pre-session state: files at
    // top level (not in category dirs) and the memory absent.
    const res = await dispatchTool('undo_session', { sessionId: 'sess-undo-test' });
    assert.equal(res.undoneCount, 3, `expected 3 undone, got ${res.undoneCount}`);
    assert.ok(await statExists(path.join(dir, 'x.jpg')));
    assert.ok(await statExists(path.join(dir, 'y.md')));
    assert.ok(!(await statExists(path.join(dir, 'Images'))));

    const { memGetFull } = await import('../lib/store.js');
    assert.equal(await memGetFull('sess-mem'), null, 'memory rolled back to pre-session (absent) state');

    delete process.env.AGENT_SESSION_ID;
  });

  it('list_undo reports undone state', async () => {
    const { dispatchTool } = await import('../tools.js');
    const all = await dispatchTool('list_undo', { pendingOnly: false, limit: 100 });
    assert.ok(all.count >= 5, 'journal has accumulated records');
    const undoneOnes = all.actions.filter((a) => a.undone);
    assert.ok(undoneOnes.length >= 3, 'previously undone records marked');
  });
});

async function statExists(p) {
  try {
    await fs.stat(p);
    return true;
  } catch {
    return false;
  }
}
