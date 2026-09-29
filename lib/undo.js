// Undo/transaction layer (vision item #2): every mutating tool action gets a
// reversal record in the DuckDB `undo_journal`. The dispatcher captures
// before/after state around execution, and undo_last/undo_session apply the
// stored reversal procedures. `run_workflow`/`execute_plan` pass the capture
// hooks through so nested dispatches are journaled too (see tools.js).
//
// Reversibility is honest, not aspirational:
//   automatic — reversal is fully determined by the record (file ops, deletes)
//   manual    — before-state recorded, but a human must decide how to reverse
//               (shell commands, computer use). Undo surfaces it, never runs it.
import fs from 'fs/promises';
import path from 'path';
import { resolveSafePath } from './fs-safety.js';

// ---------- fs snapshots ----------

// Capture everything needed to restore `p` later: content for small files,
// metadata for directories/large files. Missing files record null (the op
// likely created them).
export async function snapshotPath(p) {
  const st = await fs.stat(p).catch(() => null);
  if (!st) return { path: p, exists: false };
  if (st.isDirectory()) {
    return { path: p, exists: true, isDirectory: true };
  }
  try {
    const content = await fs.readFile(p);
    return {
      path: p,
      exists: true,
      isDirectory: false,
      size: st.size,
      mode: st.mode,
      content: content.length <= 2 * 1024 * 1024
        ? content.toString('base64')
        : null, // >2MB: too big to inline; restored as empty + flagged
      tooLarge: content.length > 2 * 1024 * 1024,
    };
  } catch (err) {
    return { path: p, exists: true, error: err.message };
  }
}

async function restoreOneSnapshot(s) {
  if (!s) return;
  if (!s.exists) {
    await fs.rm(s.path, { recursive: true, force: true });
    return;
  }
  if (s.isDirectory) {
    await fs.mkdir(s.path, { recursive: true });
    return;
  }
  if (s.content === null && s.exists && !s.isDirectory) {
    if (s.tooLarge) throw new Error(`cannot auto-restore ${s.path}: original exceeded 2MB inline limit`);
    await fs.writeFile(s.path, Buffer.alloc(0));
    return;
  }
  const buf = Buffer.from(s.content || '', 'base64');
  await fs.mkdir(path.dirname(s.path), { recursive: true });
  await fs.writeFile(s.path, buf, { mode: s.mode });
}

// ---------- reversal appliers (undo/redo descriptors) ----------

export async function applyUndoOp(op) {
  if (!op || typeof op !== 'object') throw new Error('undo op must be an object');
  switch (op.type) {
    case 'restore_snapshot':
      return restoreOneSnapshot(op.snapshot);
    case 'rename': {
      // Reverse a rename/move: put the file back where it came from. When a
      // pre-run destination snapshot exists (overwritten file), restore its
      // content after moving the current occupant out of the way.
      await fs.mkdir(path.dirname(op.from), { recursive: true });
      await fs.rename(op.to, op.from);
      if (op.destSnapshot && op.destSnapshot.exists) {
        await restoreOneSnapshot(op.destSnapshot);
      }
      return;
    }
    case 'delete_paths':
      for (const p of op.paths || []) await fs.rm(p, { recursive: true, force: true });
      return;
    case 'delete_memory':
    case 'delete_workflow': {
      // Row payloads are stored verbatim in before/after; reversal is a
      // generic upsert performed by the caller (store-backed tools) — here we
      // only validate the descriptor shape.
      if (!op.store || typeof op.store !== 'string') throw new Error('delete op requires a store name');
      return;
    }
    default:
      throw new Error(`unknown undo op type: ${op.type}`);
  }
}

// ---------- before-capture hooks (per tool) ----------

// Pre-execution state capture. `args` are raw tool args; safe path resolution
// happens here so undo records carry absolute, sandbox-verified paths.
export async function captureBefore(tool, args) {
  try {
    switch (tool) {
      case 'file_organize': {
        const dir = resolveSafePath(args?.folderPath);
        const entries = await fs.readdir(dir, { withFileTypes: true }).catch(() => []);
        const files = entries.filter((e) => e.isFile()).map((e) => e.name);
        const existingDirs = entries.filter((e) => e.isDirectory()).map((e) => e.name);
        // Snapshot existing category subdirs so an overwritten destination
        // (same-named file already in the category folder) can be restored.
        const destSnapshots = {};
        for (const e of existingDirs) {
          const sub = path.join(dir, e);
          for (const f of await fs.readdir(sub, { withFileTypes: true }).catch(() => [])) {
            if (!f.isFile()) continue;
            const p = path.join(sub, f.name);
            const snap = await snapshotPath(p);
            if (snap.exists && !snap.isDirectory && !snap.tooLarge && snap.size <= 256 * 1024) {
              destSnapshots[p] = snap;
            }
          }
        }
        return { kind: 'file_organize', dir, files, existingDirs, destSnapshots };
      }
      case 'file_rename': {
        const dir = resolveSafePath(args?.folderPath);
        const entries = await fs.readdir(dir, { withFileTypes: true }).catch(() => []);
        const files = entries.filter((e) => e.isFile()).map((e) => e.name);
        // Limitation: a template collision (new name matching an existing
        // file) overwrites content that is not snapshotted here — recorded
        // as a residual risk on the journal entry.
        return { kind: 'file_rename', dir, files };
      }
      case 'file_convert': {
        const src = resolveSafePath(args?.filePath);
        return { kind: 'file_convert', source: src, sourceSnapshot: await snapshotPath(src) };
      }
      case 'remember':
      case 'forget': {
        const { memGetFull } = await import('./store.js');
        const key = String(args?.key || '').trim();
        const prev = await memGetFull(key).catch(() => null);
        return { kind: 'memory', key, previous: prev ? { ...prev } : null };
      }
      case 'save_workflow':
      case 'delete_workflow': {
        const { wfGet } = await import('./store.js');
        const name = String(args?.name || '').trim();
        return { kind: 'workflow', name, previous: (await wfGet(name)) || null };
      }
      default:
        return { kind: 'unknown' };
    }
  } catch (err) {
    return { kind: 'capture_failed', error: err.message };
  }
}

// ---------- after-capture hooks: build the journal entry ----------

// Post-execution reversal descriptor. Returns { reversibility, before, after,
// undo, redo } or null for non-mutating outcomes.
export async function captureAfter(tool, args, result, before) {
  try {
    if (!result || result.error) return null;
    switch (tool) {
      case 'file_organize': {
        const moved = (result.details || []).filter((m) => !m.error);
        if (!moved.length) return null;
        const destSnapshots = before?.destSnapshots || {};
        // Category dirs that did not exist before the run should be removed
        // again on undo (they were created by organizeFolder's mkdir pass).
        const existingDirs = new Set((before?.existingDirs || []).map((d) => d.toLowerCase()));
        const createdDirs = [...new Set(moved.map((m) => path.dirname(m.to)))].filter(
          (d) => !existingDirs.has(path.basename(d).toLowerCase())
        );
        return {
          reversibility: 'automatic',
          before: { dir: before?.dir, files: before?.files },
          after: { movedCount: moved.length },
          undo: {
            type: 'rename_batch',
            // Reversed by renaming dest back to source; if a dest overwrote
            // an existing file, its pre-run snapshot restores that content.
            ops: moved.map((m) => ({
              type: 'rename',
              from: m.from,
              to: m.to,
              destSnapshot: destSnapshots[m.to] || null,
            })),
            removeEmptyDirs: createdDirs,
          },
          redo: {
            type: 'rename_batch',
            ops: moved.map((m) => ({ type: 'rename', from: m.to, to: m.from })),
          },
        };
      }
      case 'file_rename': {
        const renamed = (result.details || []).filter((r) => !r.error && r.from !== r.to);
        if (!renamed.length) return null;
        return {
          reversibility: 'automatic',
          before: { dir: before?.dir, files: before?.files },
          after: { renamedCount: renamed.length },
          limitation: 'template collisions with pre-existing files are not recoverable',
          undo: {
            type: 'rename_batch',
            ops: renamed.map((r) => ({ type: 'rename', from: r.from, to: r.to })),
          },
          redo: {
            type: 'rename_batch',
            ops: renamed.map((r) => ({ type: 'rename', from: r.to, to: r.from })),
          },
        };
      }
      case 'file_convert': {
        if (!result.output) return null;
        return {
          reversibility: 'automatic',
          before: { source: result.source },
          after: { output: result.output },
          undo: { type: 'delete_paths', paths: [result.output] },
          redo: null, // re-running the conversion is the redo
        };
      }
      case 'remember': {
        const key = String(args?.key || '').trim();
        const prev = before?.previous || null;
        return {
          reversibility: 'automatic',
          before: prev,
          after: { key, value: String(args?.value ?? ''), category: args?.category || 'fact' },
          undo: prev
            ? { type: 'memory_upsert', store: 'memories', row: { key, ...prev } }
            : { type: 'memory_delete', store: 'memories', key },
          redo: { type: 'memory_upsert', store: 'memories', row: { key, value: String(args?.value ?? ''), category: args?.category || 'fact' } },
        };
      }
      case 'forget': {
        const key = String(args?.key || '').trim();
        const prev = before?.previous || null;
        if (!prev) return null; // nothing existed; forget changed nothing
        return {
          reversibility: 'automatic',
          before: prev,
          after: null,
          undo: { type: 'memory_upsert', store: 'memories', row: { key, ...prev } },
          redo: { type: 'memory_delete', store: 'memories', key },
        };
      }
      case 'save_workflow':
      case 'delete_workflow': {
        const prev = before?.previous || null;
        if (tool === 'save_workflow' && !prev) {
          return {
            reversibility: 'automatic',
            before: null,
            after: { name: args?.name },
            undo: { type: 'workflow_delete', store: 'workflows', name: args?.name },
            redo: null,
          };
        }
        if (!prev) return null;
        const isDelete = tool === 'delete_workflow';
        return {
          reversibility: 'automatic',
          before: prev,
          after: isDelete ? null : { name: args?.name },
          undo: { type: 'workflow_upsert', store: 'workflows', row: prev },
          redo: isDelete
            ? { type: 'workflow_delete', store: 'workflows', name: prev.name }
            : { type: 'workflow_upsert', store: 'workflows', row: prev },
        };
      }
      case 'run_command':
      case 'terminal_execute':
      case 'computer_use': {
        return {
          reversibility: 'manual',
          before: before?.kind === 'unknown' ? null : before,
          after: { summary: describeResult(result) },
          undo: null, // human decides; surfaces what changed
          redo: null,
        };
      }
      default:
        return null;
    }
  } catch (err) {
    return {
      reversibility: 'manual',
      before: before || null,
      after: null,
      undo: null,
      redo: null,
      captureError: err.message,
    };
  }
}

function describeResult(result) {
  if (result == null) return 'completed';
  if (typeof result === 'string') return result.slice(0, 200);
  if (typeof result === 'object') {
    return JSON.stringify(result).slice(0, 200);
  }
  return String(result).slice(0, 200);
}

// ---------- applying stored records ----------

// Apply one undo record's stored descriptor. Descriptors are stored as JSON
// text in the journal, so parse defensively (store rows arrive as strings).
// Row-store reversals (memory / workflow upserts) are executed here against
// the store; fs ops go through applyUndoOp. Returns a human-readable summary.
export async function applyRecord(record, direction = 'undo') {
  let desc = direction === 'undo' ? record.undo : record.redo;
  if (typeof desc === 'string') {
    try { desc = JSON.parse(desc); } catch { /* handled below */ }
  }
  if (!desc || typeof desc !== 'object') throw new Error(`record #${record.id} has no ${direction} procedure (reversibility: ${record.reversibility})`);
  const applied = [];
  switch (desc.type) {
    case 'memory_upsert': {
      const { memSet } = await import('./store.js');
      await memSet(desc.row.key, desc.row.value, desc.row.category || 'fact');
      applied.push(`restored memory "${desc.row.key}"`);
      break;
    }
    case 'memory_delete': {
      const { memDelete } = await import('./store.js');
      await memDelete(desc.key);
      applied.push(`removed memory "${desc.key}"`);
      break;
    }
    case 'workflow_upsert': {
      const { wfSave } = await import('./store.js');
      await wfSave(desc.row.name, desc.row.steps, desc.row.description || '');
      applied.push(`restored workflow "${desc.row.name}"`);
      break;
    }
    case 'workflow_delete': {
      const { wfDelete } = await import('./store.js');
      await wfDelete(desc.name);
      applied.push(`removed workflow "${desc.name}"`);
      break;
    }
    case 'rename_batch': {
      for (const op of desc.ops || []) {
        await applyUndoOp(op);
        applied.push(`${path.basename(op.to)} → ${path.basename(op.from)}`);
      }
      // Dirs the original run created are removed again — non-recursive, so
      // a dir that gained other content in the meantime is left untouched.
      for (const d of desc.removeEmptyDirs || []) {
        await fs.rmdir(d).catch(() => {});
      }
      break;
    }
    default: {
      await applyUndoOp(desc);
      applied.push(desc.type);
    }
  }
  return applied;
}

// ---------- workflow/plan passthrough helpers ----------

// run_workflow/execute_plan call the real dispatcher for each step. These
// wrappers let them forward session/plan identity onto the journal so
// "undo the whole workflow/plan" works later.
export function makeNestedCapture({ sessionId, planId, agentId }) {
  return { sessionId, planId, agentId };
}
