/**
 * PC Assistant Terminal Monitor — Ink edition
 *
 * Real-time TUI fed by the server's SSE event stream (/api/events):
 * status, audio waveform, live transcript, tool calls, and pending
 * approvals with a direct link to the confirmation UI.
 *
 * No build step: JSX-free React via createElement (h alias).
 */

import React, { useState, useEffect } from 'react';
import { render, Text, Box, useApp } from 'ink';
import { createEventStream } from './lib/event-client.js';

const h = React.createElement;

const BAR_CHARS = ['▁', '▂', '▃', '▄', '▅', '▆', '▇', '█'];
const MAX_AUDIO = 48;
const MAX_TRANSCRIPT = 14;
const MAX_TOOLS = 8;

function barChar(level) {
  // RMS ~0..20000; log-ish scale into 8 buckets.
  const idx = Math.min(BAR_CHARS.length - 1, Math.floor(Math.sqrt(Math.max(0, level)) / 18));
  return BAR_CHARS[idx];
}

function Header({ connected, status, pending, activeTools }) {
  const connColor = connected ? 'green' : 'red';
  const connLabel = connected ? 'stream connected' : 'server offline — retrying…';
  const statusColor =
    status === 'recording' ? 'red' : status === 'ready' || status === 'connected' ? 'green' : status === 'error' ? 'red' : 'yellow';
  return h(
    Box,
    { flexDirection: 'column', borderStyle: 'round', borderColor: 'cyan', paddingX: 1 },
    h(Box, { justifyContent: 'space-between' }, [
      h(Text, { key: 't', bold: true, color: 'cyan' }, '🎙️  PC ASSISTANT MONITOR'),
      h(Text, { key: 'c', color: connColor }, connected ? '● ' + connLabel : '○ ' + connLabel),
    ]),
    h(Box, { gap: 2 }, [
      h(Text, { key: 's' }, [
        h(Text, { key: 'l', color: 'gray' }, 'status '),
        h(Text, { key: 'v', color: statusColor, bold: true }, status),
      ]),
      h(Text, { key: 'tools' }, [
        h(Text, { key: 'l', color: 'gray' }, 'tools '),
        h(Text, { key: 'v', bold: activeTools > 0, color: activeTools > 0 ? 'yellow' : 'default' }, `${activeTools} active`),
      ]),
      h(Text, { key: 'appr' }, [
        h(Text, { key: 'l', color: 'gray' }, 'approvals '),
        h(Text, { key: 'v', bold: pending > 0, color: pending > 0 ? 'red' : 'green' }, `${pending} pending`),
      ]),
    ])
  );
}

function AudioPanel({ levels, latest }) {
  return h(
    Box,
    { flexDirection: 'column', borderStyle: 'round', borderColor: 'gray', paddingX: 1 },
    h(Text, { color: 'gray' }, 'AUDIO'),
    h(
      Text,
      null,
      levels.length
        ? levels.map((l, i) =>
            h(
              Text,
              { key: i, color: l.isSpeech ? 'green' : 'gray' },
              barChar(l.level)
            )
          )
        : '—'
    ),
    h(Text, { color: 'gray' }, latest ? `level ${Math.floor(latest.level)}   speech: ${latest.isSpeech ? 'yes' : 'no'}` : 'waiting for audio…')
  );
}

function TranscriptPanel({ items }) {
  return h(
    Box,
    { flexDirection: 'column', borderStyle: 'round', borderColor: 'magenta', paddingX: 1, minHeight: 6 },
    h(Text, { color: 'gray' }, 'CONVERSATION'),
    ...(items.length
      ? items.map((m, i) =>
          h(
            Text,
            { key: i, wrap: 'truncate' },
            h(Text, { color: m.speaker === 'user' ? 'cyan' : 'magenta', bold: true }, m.speaker === 'user' ? '👤 You  ' : '🤖 AI    '),
            m.text
          )
        )
      : [h(Text, { key: 'empty', color: 'gray' }, 'say something…')]),
    items.length ? null : null
  );
}

function ToolsPanel({ items }) {
  return h(
    Box,
    { flexDirection: 'column', borderStyle: 'round', borderColor: 'yellow', paddingX: 1 },
    h(Text, { color: 'gray' }, 'TOOL CALLS'),
    ...(items.length
      ? items.map((t) => {
          const mark = t.status === 'running' ? '⏳' : t.status === 'completed' ? '✅' : '❌';
          const color = t.status === 'running' ? 'yellow' : t.status === 'completed' ? 'green' : 'red';
          const args = Object.entries(t.args || {})
            .map(([k, v]) => `${k}=${String(v).slice(0, 24)}`)
            .slice(0, 3)
            .join(' ');
          return h(Text, { key: t.callId, wrap: 'truncate' }, [
            h(Text, { key: 'n', color }, `${mark} ${t.toolName} `),
            h(Text, { key: 'a', color: 'gray' }, args),
          ]);
        })
      : [h(Text, { key: 'empty', color: 'gray' }, 'none yet')]),
    items.length ? null : null
  );
}

function ApprovalsPanel({ items }) {
  const port = process.env.PORT || '3000';
  return h(
    Box,
    { flexDirection: 'column', borderStyle: 'round', borderColor: items.length ? 'red' : 'gray', paddingX: 1 },
    h(Text, { color: items.length ? 'red' : 'gray', bold: items.length > 0 }, `🔒 APPROVALS${items.length ? ' — ACTION NEEDED' : ''}`),
    ...(items.length
      ? [
          ...items.map((a) =>
            h(
              Box,
              { key: a.approvalId, flexDirection: 'column' },
              h(Text, { color: 'red', bold: true }, `⚠  ${a.toolName}`),
              h(
                Text,
                { color: 'gray', wrap: 'truncate' },
                Object.entries(a.args || {})
                  .map(([k, v]) => `${k}=${String(v).slice(0, 40)}`)
                  .join('  ')
              )
            )
          ),
          h(
            Text,
            { key: 'hint', color: 'yellow' },
            `→ decide at http://localhost:${port}/api/confirm  (or the /dashboard panel)`
          ),
        ]
      : [h(Text, { key: 'empty', color: 'gray' }, 'queue clear')]),
    items.length ? null : null
  );
}

function ErrorToast({ message }) {
  if (!message) return null;
  return h(Text, { color: 'red' }, `✖ ${message}`);
}

function App() {
  const { exit } = useApp();
  const [connected, setConnected] = useState(false);
  const [status, setStatus] = useState('offline');
  const [audio, setAudio] = useState([]);
  const [transcript, setTranscript] = useState([]);
  const [tools, setTools] = useState([]);
  const [approvals, setApprovals] = useState([]);
  const [error, setError] = useState('');
  const [clock, setClock] = useState(() => new Date().toLocaleTimeString());

  useEffect(() => {
    const t = setInterval(() => setClock(new Date().toLocaleTimeString()), 1000);
    return () => clearInterval(t);
  }, []);

  useEffect(() => {
    let errTimer;
    const showError = (msg) => {
      setError(msg);
      clearTimeout(errTimer);
      errTimer = setTimeout(() => setError(''), 4000);
    };

    const port = process.env.PORT || '3000';
    const stream = createEventStream(`http://localhost:${port}`);

    stream.on('connected', () => setConnected(true));
    stream.on('disconnected', () => setConnected(false));
    stream.on('reconnecting', () => setConnected(false));
    stream.on('error', () => setConnected(false));

    stream.on('event', (event) => {
      switch (event.type) {
        case 'connected':
          setConnected(true);
          break;
        case 'state': {
          const s = String(event.data.state || '');
          setStatus(
            { recording: 'recording', ready: 'ready', connected: 'connected', resumed: 'ready', resuming: 'resuming', initializing: 'init', error: 'error' }[s] ||
              s ||
              'idle'
          );
          break;
        }
        case 'transcript': {
          const { speaker, text, isDelta } = event.data;
          setTranscript((prev) => {
            if (isDelta && prev.length && prev[prev.length - 1].speaker === speaker && prev[prev.length - 1].partial) {
              const copy = prev.slice();
              copy[copy.length - 1] = { ...copy[copy.length - 1], text: copy[copy.length - 1].text + text };
              return copy;
            }
            const next = [...prev, { speaker, text, partial: !!isDelta }];
            return next.slice(-MAX_TRANSCRIPT);
          });
          break;
        }
        case 'tool_call': {
          const { toolName, args, callId } = event.data;
          setTools((prev) => [{ toolName, args, callId, status: 'running' }, ...prev].slice(0, MAX_TOOLS));
          break;
        }
        case 'tool_result': {
          const { toolName, callId, success } = event.data;
          setTools((prev) =>
            prev.map((t) => (!callId || t.callId === callId || t.toolName === toolName) && t.status === 'running'
              ? { ...t, status: success ? 'completed' : 'failed' }
              : t)
          );
          break;
        }
        case 'audio_level':
          setAudio((prev) => [...prev.slice(-(MAX_AUDIO - 1)), event.data]);
          break;
        case 'approval_request': {
          const { toolName, args, approvalId } = event.data;
          setApprovals((prev) => (prev.some((p) => p.approvalId === approvalId) ? prev : [...prev, { toolName, args, approvalId }]));
          break;
        }
        case 'approval_resolved': {
          const { approvalId } = event.data;
          setApprovals((prev) => prev.filter((p) => p.approvalId !== approvalId));
          break;
        }
        case 'error':
          showError(event.data.message || 'agent error');
          break;
      }
    });

    const onSigint = () => exit();
    process.on('SIGINT', onSigint);
    return () => {
      process.off('SIGINT', onSigint);
      clearTimeout(errTimer);
      stream.close();
    };
  }, []);

  const activeTools = tools.filter((t) => t.status === 'running').length;
  const latestAudio = audio[audio.length - 1];

  return h(
    Box,
    { flexDirection: 'column', gap: 1, paddingX: 1 },
    h(Header, { connected, status, pending: approvals.length, activeTools }),
    h(AudioPanel, { levels: audio, latest: latestAudio }),
    h(TranscriptPanel, { items: transcript }),
    h(ToolsPanel, { items: tools }),
    h(ApprovalsPanel, { items: approvals }),
    h(ErrorToast, { message: error }),
    h(Text, { color: 'gray' }, `${clock}  ·  Ctrl+C to exit  ·  setup http://localhost:${process.env.PORT || '3000'}/setup`)
  );
}

const isMain = process.argv[1] && process.argv[1].endsWith('tui.js');
if (isMain) {
  render(h(App), { exitOnCtrlC: true });
}

export { App };
