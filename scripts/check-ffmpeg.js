// FFmpeg device probe — helps users find the right AUDIO_DEVICE value.
// Usage: node scripts/check-ffmpeg.js [--play]
//   Lists input devices (Windows: dshow, macOS: avfoundation, Linux: alsa)
//   and verifies a 2s capture works.
import { spawn, execFile } from 'child_process';
import { promisify } from 'util';

const execFileAsync = promisify(execFile);
const SHOULD_PLAY = process.argv.includes('--play');

console.log(`Platform: ${process.platform}\n`);

async function listDevices() {
  try {
    if (process.platform === 'win32') {
      const { stderr } = await execFileAsync('ffmpeg', ['-f', 'dshow', '-list_devices', 'true', '-i', 'dummy'], { timeout: 15000 }).catch((e) => e);
      console.log((stderr || '').slice(0, 2000) || '(no dshow output)');
      console.log('\nTip: set AUDIO_DEVICE to the quoted device name, e.g. AUDIO_DEVICE="Microphone (USB)"');
    } else if (process.platform === 'darwin') {
      const { stderr } = await execFileAsync('ffmpeg', ['-f', 'avfoundation', '-list_devices', 'true', '-i', ''], { timeout: 15000 }).catch((e) => e);
      console.log((stderr || '').slice(0, 2000));
    } else {
      const { stdout } = await execFileAsync('arecord', ['-l'], { timeout: 10000 }).catch(() => ({ stdout: '(arecord not found)' }));
      console.log(stdout);
    }
  } catch (e) {
    console.error('Device listing failed:', e.message);
  }
}

async function testCapture() {
  console.log('\nTesting 2s capture…');
  const isWindows = process.platform === 'win32';
  const device = process.env.AUDIO_DEVICE || (isWindows ? 'default' : ':default');
  const args = isWindows
    ? ['-f', 'dshow', '-i', `audio=${device}`, '-t', '2', '-ar', '16000', '-ac', '1', '-f', 's16le', '-']
    : process.platform === 'darwin'
      ? ['-f', 'avfoundation', '-i', device, '-t', '2', '-ar', '16000', '-ac', '1', '-f', 's16le', '-']
      : ['-f', 'alsa', '-i', process.env.AUDIO_DEVICE || 'default', '-t', '2', '-ar', '16000', '-ac', '1', '-f', 's16le', '-'];
  const p = spawn('ffmpeg', args, { stdio: ['ignore', 'pipe', 'pipe'] });
  let bytes = 0;
  p.stdout.on('data', (d) => (bytes += d.length));
  const code = await new Promise((resolve) => p.on('close', resolve));
  // 2s @ 32KB/s ≈ 64KB expected
  console.log(`Captured ${bytes} bytes (expected ~64000). Exit code: ${code}`);
  console.log(bytes > 32000 ? '✅ capture works' : '❌ capture produced too little audio — check AUDIO_DEVICE');
}

await listDevices();
await testCapture();

if (SHOULD_PLAY) {
  console.log('\nPlaying test tone…');
  const tone = spawn('ffplay', ['-nodisp', '-autoexit', '-f', 'lavfi', '-i', 'sine=frequency=440:duration=1'], { stdio: 'ignore' });
  await new Promise((r) => tone.on('close', r));
}
