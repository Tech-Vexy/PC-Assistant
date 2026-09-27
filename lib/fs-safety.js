// Path-safety helpers for file-system-touching tools (file-manager, dev-workflow).
//
// Two safety models:
//   - resolveSafePath(): for general file-manager tools (organize/rename/convert/find)
//     that need to touch arbitrary user files. Confined to the user's home
//     directory (plus optional FILE_TOOL_ALLOWED_ROOTS config), with a
//     defense-in-depth blocklist for sensitive system fragments even inside
//     the home tree (junctions/symlinks, .ssh, credential stores, etc).
//   - resolveWorkspacePath(): for developer-workflow tools (list_files,
//     search_code, read_file, run_tests) confined strictly to the project
//     workspace root (cwd, or WORKSPACE_ROOT override).
//
// Both throw on escape/traversal attempts rather than silently clamping, so
// callers surface a clear error instead of acting on an unintended path.
import path from 'path';
import os from 'os';
import { cfg } from './store.js';

const BLOCKED_FRAGMENTS = [
  'windows\\system32',
  'windows/system32',
  '\\programdata\\',
  '/etc/',
  '.ssh',
  '.gnupg',
  'ntds.dit',
  'sam.hive',
  'keychain',
];

function isWin() {
  return process.platform === 'win32';
}

function norm(p) {
  return isWin() ? p.toLowerCase() : p;
}

function withinRoot(resolved, root) {
  const nr = norm(resolved);
  const nroot = norm(root);
  return nr === nroot || nr.startsWith(nroot + path.sep);
}

function getAllowedRoots() {
  const home = path.resolve(os.homedir());
  const extraRaw = cfg('FILE_TOOL_ALLOWED_ROOTS', '');
  const extras = extraRaw
    ? extraRaw
        .split(path.delimiter)
        .map((p) => p.trim())
        .filter(Boolean)
        .map((p) => path.resolve(p))
    : [];
  return [home, ...extras];
}

function assertNoBlockedFragments(resolved, original) {
  const lower = resolved.toLowerCase();
  for (const frag of BLOCKED_FRAGMENTS) {
    if (lower.includes(frag)) {
      throw new Error(`Access to "${original}" is blocked (sensitive system path)`);
    }
  }
}

/** Resolve a user-supplied path, confined to the home directory (or configured extra roots). */
export function resolveSafePath(inputPath) {
  if (!inputPath || typeof inputPath !== 'string') {
    throw new Error('path must be a non-empty string');
  }
  const resolved = path.resolve(inputPath);
  const roots = getAllowedRoots();
  if (!roots.some((root) => withinRoot(resolved, root))) {
    throw new Error(`Path "${inputPath}" is outside the allowed directories (${roots.join(', ')})`);
  }
  assertNoBlockedFragments(resolved, inputPath);
  return resolved;
}

/** Resolve a path confined strictly to the project workspace root. */
export function resolveWorkspacePath(subPath = '.') {
  const root = path.resolve(process.env.WORKSPACE_ROOT || process.cwd());
  const resolved = path.resolve(root, subPath || '.');
  if (!withinRoot(resolved, root)) {
    throw new Error(`Path "${subPath}" escapes the workspace root`);
  }
  return resolved;
}
