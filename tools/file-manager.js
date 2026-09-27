// File & document management tools (domain 4): organize folders, rename
// files, convert documents, and locate files by name/content — confined to
// the user's home directory via lib/fs-safety.js (resolveSafePath).
import fs from 'fs/promises';
import path from 'path';
import { execFile } from 'child_process';
import { promisify } from 'util';
import { resolveSafePath } from '../lib/fs-safety.js';

const execFileAsync = promisify(execFile);

const EXT_CATEGORIES = {
  Images: ['.jpg', '.jpeg', '.png', '.gif', '.bmp', '.webp', '.svg', '.heic', '.tiff'],
  Documents: ['.pdf', '.doc', '.docx', '.txt', '.rtf', '.odt', '.md'],
  Spreadsheets: ['.xls', '.xlsx', '.csv', '.ods'],
  Presentations: ['.ppt', '.pptx', '.odp'],
  Archives: ['.zip', '.rar', '.7z', '.tar', '.gz'],
  Audio: ['.mp3', '.wav', '.flac', '.aac', '.ogg', '.m4a'],
  Video: ['.mp4', '.mov', '.avi', '.mkv', '.webm'],
  Code: ['.js', '.ts', '.py', '.java', '.c', '.cpp', '.json', '.html', '.css'],
  Executables: ['.exe', '.msi', '.bat', '.sh'],
};

function categoryFor(ext) {
  const lower = ext.toLowerCase();
  for (const [cat, exts] of Object.entries(EXT_CATEGORIES)) {
    if (exts.includes(lower)) return cat;
  }
  return 'Other';
}

export async function organizeFolder(args) {
  const { folderPath, dryRun = false } = args;
  const dir = resolveSafePath(folderPath);
  const entries = await fs.readdir(dir, { withFileTypes: true });
  const moves = [];

  for (const entry of entries) {
    if (entry.isDirectory()) continue;
    const ext = path.extname(entry.name);
    const category = categoryFor(ext);
    const destDir = path.join(dir, category);
    const src = path.join(dir, entry.name);
    const dest = path.join(destDir, entry.name);
    moves.push({ from: src, to: dest, category });
  }

  if (!dryRun) {
    const categories = [...new Set(moves.map((m) => m.category))];
    for (const cat of categories) {
      await fs.mkdir(path.join(dir, cat), { recursive: true });
    }
    for (const m of moves) {
      try {
        await fs.rename(m.from, m.to);
      } catch (err) {
        m.error = err.message;
      }
    }
  }

  return {
    success: true,
    dryRun,
    folder: dir,
    moved: moves.filter((m) => !m.error).length,
    failed: moves.filter((m) => m.error).length,
    details: moves,
  };
}
// 2. Rename files in a folder using a template (supports {name}, {ext}, {index}, {date}).
export async function renameFiles(args) {
  const { folderPath, pattern, template, dryRun = false } = args;
  const dir = resolveSafePath(folderPath);
  const entries = (await fs.readdir(dir, { withFileTypes: true })).filter((e) => e.isFile());
  const re = pattern ? new RegExp(pattern, 'i') : null;
  const matched = re ? entries.filter((e) => re.test(e.name)) : entries;

  const results = [];
  let index = 1;
  const dateStr = new Date().toISOString().slice(0, 10);
  for (const entry of matched) {
    const ext = path.extname(entry.name);
    const base = path.basename(entry.name, ext);
    const newName = (template || '{name}')
      .replace('{name}', base)
      .replace('{ext}', ext.replace('.', ''))
      .replace('{index}', String(index).padStart(3, '0'))
      .replace('{date}', dateStr) + (template && template.includes('{ext}') ? '' : ext);
    const from = path.join(dir, entry.name);
    const to = path.join(dir, newName);
    results.push({ from, to });
    if (!dryRun && from !== to) {
      try {
        await fs.rename(from, to);
      } catch (err) {
        results[results.length - 1].error = err.message;
      }
    }
    index++;
  }

  return {
    success: true,
    dryRun,
    folder: dir,
    renamed: results.filter((r) => !r.error).length,
    failed: results.filter((r) => r.error).length,
    details: results,
  };
}
// 3. Find files by name pattern and/or text content under a folder (recursive, depth-limited).
export async function findFiles(args) {
  const { folderPath, namePattern, contentQuery, maxResults = 20, maxDepth = 6 } = args;
  const dir = resolveSafePath(folderPath);
  const nameRe = namePattern ? new RegExp(namePattern, 'i') : null;
  const matches = [];

  async function walk(current, depth) {
    if (matches.length >= maxResults || depth > maxDepth) return;
    let entries;
    try {
      entries = await fs.readdir(current, { withFileTypes: true });
    } catch {
      return;
    }
    for (const entry of entries) {
      if (matches.length >= maxResults) return;
      const full = path.join(current, entry.name);
      if (entry.isDirectory()) {
        await walk(full, depth + 1);
        continue;
      }
      if (nameRe && !nameRe.test(entry.name)) continue;
      if (contentQuery) {
        try {
          const stat = await fs.stat(full);
          if (stat.size > 5 * 1024 * 1024) continue; // skip huge files for content search
          const content = await fs.readFile(full, 'utf8').catch(() => null);
          if (content === null || !content.toLowerCase().includes(String(contentQuery).toLowerCase())) continue;
        } catch {
          continue;
        }
      }
      matches.push(full);
    }
  }

  await walk(dir, 0);
  return { success: true, folder: dir, count: matches.length, files: matches };
}
// 4. Convert documents between formats using LibreOffice (soffice) headless mode when available.
export async function convertDocument(args) {
  const { filePath, targetFormat } = args;
  const src = resolveSafePath(filePath);
  const fmt = String(targetFormat || '').toLowerCase().replace(/^\./, '');
  if (!fmt || !/^[a-z0-9]+$/.test(fmt)) {
    throw new Error('targetFormat must be a simple extension like "pdf" or "docx"');
  }
  const outDir = path.dirname(src);
  const sofficeCandidates = process.platform === 'win32'
    ? ['soffice.exe', 'soffice']
    : ['soffice', 'libreoffice'];

  let lastErr = null;
  for (const bin of sofficeCandidates) {
    try {
      await execFileAsync(bin, ['--headless', '--convert-to', fmt, '--outdir', outDir, src], { timeout: 60000 });
      const base = path.basename(src, path.extname(src));
      const outPath = path.join(outDir, `${base}.${fmt}`);
      const exists = await fs.stat(outPath).then(() => true).catch(() => false);
      if (exists) {
        return { success: true, source: src, output: outPath, format: fmt };
      }
      lastErr = new Error('Conversion reported success but output file was not found');
    } catch (err) {
      lastErr = err;
    }
  }
  throw new Error(
    `Document conversion failed (LibreOffice/soffice not found or conversion error): ${lastErr?.message || 'unknown error'}. ` +
    'Install LibreOffice and ensure "soffice" is on PATH.'
  );
}