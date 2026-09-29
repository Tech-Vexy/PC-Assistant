// FFmpeg device probe — helps users find the right AUDIO_DEVICE value.
// Usage: node scripts/check-ffmpeg.js [--play]
//   Lists input devices (Windows: dshow, macOS: avfoundation, Linux: alsa)
//   and verifies a 2s capture works. On Windows without AUDIO_DEVICE set,
//   every detected microphone is tested and a working one is suggested.
import { spawn, execFile } from 'child_process';
import { promisify } from 'util';
import dotenv from 'dotenv';

// Load .env so "Testing configured AUDIO_DEVICE" reflects what the agent sees.
dotenv.config();

const execFileAsync = promisify(execFile);
const SHOULD_PLAY = process.argv.includes('--play');

console.log(`Platform: ${process.platform}\n`);

// Parse dshow's device dump: lines like ` "Microphone (USB)" (audio)`.
function parseDshowDevices(stderr) {
  const audio = [];
  const video = [];
  for (const line of (stderr || '').split(/\r?\n/)) {
    const m = line.match(/"(.+?)"\s+\((audio|video)\)/);
    if (m) (m[2] === 'audio' ? audio : video).push(m[1]);
  }
  return { audio, video };
}

async function listDevices() {
  try {
    if (process.platform === 'win32') {
      const { stderr } = await execFileAsync(
        'ffmpeg', ['-hide_banner', '-f', 'dshow', '-list_devices', 'true', '-i', 'dummy'],
        { timeout: 15000 }
      ).catch((e) => e);
      const { audio, video } = parseDshowDevices(stderr);
      console.log(`Audio input devices (${audio.length}):`);
      for (const d of audio) console.log(`  • ${d}`);
      if (video.length) console.log(`Video devices (not used for voice): ${video.join(', ')}`);
      if (!audio.length) {
        console.log('  (none found — check Windows Settings > Privacy > Microphone,');
        console.log('   or plug in a mic and re-run)');
      }
      return audio;
    } else if (process.platform === 'darwin') {
      const { stderr } = await execFileAsync(
        'ffmpeg', ['-hide_banner', '-f', 'avfoundation', '-list_devices', 'true', '-i', ''],
        { timeout: 15000 }
      ).catch((e) => e);
      console.log((stderr || '').slice(0, 2000));
      return [];
    } else {
      const { stdout } = await execFileAsync('arecord', ['-l'], { timeout: 10000 }).catch(() => ({ stdout: '(arecord not found)' }));
      console.log(stdout);
      return [];
    }
  } catch (e) {
    console.error('Device listing failed:', e.message);
    return [];
  }
}

// Spawn one 2s capture and resolve { bytes, code }.
function captureBytes(device) {
  const isWindows = process.platform === 'win32';
  const args = isWindows
    ? ['-hide_banner', '-f', 'dshow', '-i', `audio=${device}`, '-t', '2', '-ar', '16000', '-ac', '1', '-f', 's16le', '-']
    : process.platform === 'darwin'
      ? ['-hide_banner', '-f', 'avfoundation', '-i', device, '-t', '2', '-ar', '16000', '-ac', '1', '-f', 's16le', '-']
      : ['-hide_banner', '-f', 'alsa', '-i', device, '-t', '2', '-ar', '16000', '-ac', '1', '-f', 's16le', '-'];
  const p = spawn('ffmpeg', args, { stdio: ['ignore', 'pipe', 'pipe'] });
  let bytes = 0;
  p.stdout.on('data', (d) => (bytes += d.length));
  let errTail = '';
  p.stderr.on('data', (d) => { errTail = (errTail + d.toString()).slice(-300); });
  return new Promise((resolve) => p.on('close', (code) => resolve({ bytes, code, errTail })));
}

// 2s @ 32KB/s ≈ 64KB expected; accept anything above 32KB (~1s of audio).
async function testCapture(device) {
  const { bytes, code, errTail } = await captureBytes(device);
  const ok = bytes > 32000;
  console.log(`  captured ${bytes} bytes (expected ~64000, exit ${code}) ${ok ? '✅' : '❌'}`);
  if (!ok && errTail.trim()) console.log(`  ffmpeg said: ${errTail.trim().split(/\r?\n/).pop()}`);
  return ok;
}

const envDevice = process.env.AUDIO_DEVICE;
let workingDevice = null;

if (envDevice) {
  console.log(`\nTesting configured AUDIO_DEVICE: "${envDevice}"`);
  if (await testCapture(envDevice)) workingDevice = envDevice;
} else {
  const candidates = await listDevices();
  if (process.platform === 'win32') {
    if (candidates.length) {
      console.log('\nTesting each detected microphone (AUDIO_DEVICE is not set):');
      for (const d of candidates) {
        process.stdout.write(`  "${d}" — `);
        if (await testCapture(d)) {
          workingDevice = d;
          break;
        }
      }
    } else {
      console.log('\nNo microphones detected — nothing to test.');
    }
  } else {
    // macOS/Linux platform defaults are real ("":0/default); test them directly.
    const fallback = process.platform === 'darwin' ? ':0' : 'default';
    console.log(`\nTesting platform default device: "${fallback}"`);
    if (await testCapture(fallback)) workingDevice = fallback;
  }
}

if (workingDevice) {
  console.log(`\n✅ capture works${envDevice ? '' : ` with "${workingDevice}"`}`);
  if (!envDevice && workingDevice !== 'default' && workingDevice !== ':0') {
    console.log(`\nMake it permanent — add this line to .env:`);
    console.log(`  AUDIO_DEVICE=${workingDevice}`);
  }
} else {
  console.log('\n❌ no working capture found. Checklist:');
  console.log('  1. Windows Settings > Privacy > Microphone: allow desktop apps');
  console.log('  2. Set AUDIO_DEVICE in .env to an exact device name above');
  console.log('  3. Re-run: pnpm run check-ffmpeg');
}

if (SHOULD_PLAY) {
  console.log('\nPlaying test tone…');
  const tone = spawn('ffplay', ['-nodisp', '-autoexit', '-f', 'lavfi', '-i', 'sine=frequency=440:duration=1'], { stdio: 'ignore' });
  await new Promise((r) => tone.on('close', r));
}
