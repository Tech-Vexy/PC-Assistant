// File & document management tools (domain 4): organize folders, rename
// files, convert documents, and locate files by name/content — confined to
// the user's home directory via lib/fs-safety.js (resolveSafePath).
import fs from 'fs/promises';
import path from 'path';
import { execFile } from 'child_process';
import { promisify } from 'util';
import { resolveSafePath } from '../lib/fs-safety.js';
import { createLogger } from '../lib/monitor.js';

const execFileAsync = promisify(execFile);
const logger = createLogger('file-manager');

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
  const startTime = Date.now();
  
  try {
    const entries = await fs.readdir(dir, { withFileTypes: true });
    const moves = [];

    // Categorize files in a single pass
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
      // Create all category directories upfront (parallel for better performance)
      const categories = [...new Set(moves.map((m) => m.category))];
      await Promise.all(categories.map(cat => 
        fs.mkdir(path.join(dir, cat), { recursive: true }).catch(err => {
          logger.warn('Failed to create category directory', { category: cat, error: err.message });
        })
      ));

      // Process file moves in batches for better performance without overwhelming the system
      const BATCH_SIZE = 10;
      for (let i = 0; i < moves.length; i += BATCH_SIZE) {
        const batch = moves.slice(i, i + BATCH_SIZE);
        await Promise.all(batch.map(m => 
          fs.rename(m.from, m.to).catch(err => {
            m.error = err.message;
            logger.warn('Failed to move file', { from: m.from, to: m.to, error: err.message });
          })
        ));
      }
    }

    const duration = Date.now() - startTime;
    logger.info('Folder organization completed', { 
      folder: dir, 
      totalFiles: moves.length, 
      moved: moves.filter(m => !m.error).length,
      failed: moves.filter(m => m.error).length,
      duration 
    });

    return {
      success: true,
      dryRun,
      folder: dir,
      moved: moves.filter((m) => !m.error).length,
      failed: moves.filter((m) => m.error).length,
      details: moves,
      duration: `${duration}ms`
    };
  } catch (error) {
    logger.error('Folder organization failed', { folder: dir, error: error.message });
    throw error;
  }
}
// 2. Rename files in a folder using a template (supports {name}, {ext}, {index}, {date}).
export async function renameFiles(args) {
  const { folderPath, pattern, template, dryRun = false } = args;
  const dir = resolveSafePath(folderPath);
  const startTime = Date.now();
  
  try {
    const entries = (await fs.readdir(dir, { withFileTypes: true })).filter((e) => e.isFile());
    const re = pattern ? new RegExp(pattern, 'i') : null;
    const matched = re ? entries.filter((e) => re.test(e.name)) : entries;

    const results = [];
    let index = 1;
    const dateStr = new Date().toISOString().slice(0, 10);
    
    // Calculate all new names first (validation pass)
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
      index++;
    }

    if (!dryRun) {
      // Process renames in batches for better performance
      const BATCH_SIZE = 20;
      for (let i = 0; i < results.length; i += BATCH_SIZE) {
        const batch = results.slice(i, i + BATCH_SIZE);
        await Promise.all(batch.map(r => {
          if (r.from === r.to) return Promise.resolve(); // Skip no-op renames
          return fs.rename(r.from, r.to).catch(err => {
            r.error = err.message;
            logger.warn('Failed to rename file', { from: r.from, to: r.to, error: err.message });
          });
        }));
      }
    }

    const duration = Date.now() - startTime;
    logger.info('File renaming completed', { 
      folder: dir, 
      totalFiles: results.length, 
      renamed: results.filter(r => !r.error && r.from !== r.to).length,
      failed: results.filter(r => r.error).length,
      duration 
    });

    return {
      success: true,
      dryRun,
      folder: dir,
      renamed: results.filter((r) => !r.error && r.from !== r.to).length,
      failed: results.filter((r) => r.error).length,
      details: results,
      duration: `${duration}ms`
    };
  } catch (error) {
    logger.error('File renaming failed', { folder: dir, error: error.message });
    throw error;
  }
}
// 3. Find files by name pattern and/or text content under a folder (recursive, depth-limited).
export async function findFiles(args) {
  const { folderPath, namePattern, contentQuery, maxResults = 20, maxDepth = 6 } = args;
  const dir = resolveSafePath(folderPath);
  const nameRe = namePattern ? new RegExp(namePattern, 'i') : null;
  const matches = [];
  const startTime = Date.now();

  async function walk(current, depth) {
    if (matches.length >= maxResults || depth > maxDepth) return;
    let entries;
    try {
      entries = await fs.readdir(current, { withFileTypes: true });
    } catch {
      return;
    }
    
    // Process directory entries in parallel for better performance
    const promises = [];
    for (const entry of entries) {
      if (matches.length >= maxResults) break;
      const full = path.join(current, entry.name);
      
      if (entry.isDirectory()) {
        promises.push(walk(full, depth + 1));
        continue;
      }
      
      // Skip files that don't match name pattern
      if (nameRe && !nameRe.test(entry.name)) continue;
      
      // For content search, check file asynchronously
      if (contentQuery) {
        promises.push((async () => {
          try {
            const stat = await fs.stat(full);
            if (stat.size > 5 * 1024 * 1024) return; // skip huge files for content search
            const content = await fs.readFile(full, 'utf8').catch(() => null);
            if (content !== null && content.toLowerCase().includes(String(contentQuery).toLowerCase())) {
              matches.push(full);
            }
          } catch {
            // Skip files that can't be read
          }
        })());
      } else {
        matches.push(full);
      }
    }
    
    await Promise.all(promises);
  }

  try {
    await walk(dir, 0);
    const duration = Date.now() - startTime;
    logger.info('File search completed', { 
      folder: dir, 
      found: matches.length, 
      maxResults, 
      maxDepth,
      duration 
    });
    
    return { 
      success: true, 
      folder: dir, 
      count: matches.length, 
      files: matches,
      duration: `${duration}ms`
    };
  } catch (error) {
    logger.error('File search failed', { folder: dir, error: error.message });
    throw error;
  }
}
// 4. Convert documents between formats using LibreOffice (soffice) headless mode when available.
export async function convertDocument(args) {
  const { filePath, targetFormat } = args;
  const src = resolveSafePath(filePath);
  const startTime = Date.now();
  
  try {
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
        logger.info('Attempting document conversion', { 
          binary: bin, 
          source: src, 
          format: fmt 
        });
        
        await execFileAsync(bin, ['--headless', '--convert-to', fmt, '--outdir', outDir, src], { 
          timeout: 60000,
          maxBuffer: 10 * 1024 * 1024 // 10MB buffer for LibreOffice output
        });
        
        const base = path.basename(src, path.extname(src));
        const outPath = path.join(outDir, `${base}.${fmt}`);
        const exists = await fs.stat(outPath).then(() => true).catch(() => false);
        
        if (exists) {
          const duration = Date.now() - startTime;
          logger.info('Document conversion successful', { 
            source: src, 
            output: outPath, 
            format: fmt,
            duration 
          });
          
          return { 
            success: true, 
            source: src, 
            output: outPath, 
            format: fmt,
            duration: `${duration}ms`
          };
        }
        lastErr = new Error('Conversion reported success but output file was not found');
      } catch (err) {
        lastErr = err;
        logger.warn('Document conversion attempt failed', { 
          binary: bin, 
          error: err.message 
        });
      }
    }
    
    const duration = Date.now() - startTime;
    logger.error('Document conversion failed', { 
      source: src, 
      format: fmt, 
      duration,
      error: lastErr?.message 
    });
    
    throw new Error(
      `Document conversion failed (LibreOffice/soffice not found or conversion error): ${lastErr?.message || 'unknown error'}. ` +
      'Install LibreOffice and ensure "soffice" is on PATH.'
    );
  } catch (error) {
    logger.error('Document conversion error', { 
      filePath, 
      targetFormat, 
      error: error.message 
    });
    throw error;
  }
}