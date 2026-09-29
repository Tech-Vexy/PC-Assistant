/**
 * Event Emitter for PC Assistant
 *
 * Provides a unified event streaming interface for real-time monitoring
 * of voice agent activities. Events can be consumed by multiple clients
 * (TUI, web dashboard, monitoring tools) via SSE or WebSocket.
 *
 * Cross-process relay: the agent process (voice capture, tool dispatch,
 * approvals) is separate from the server process that hosts /api/events.
 * When setRelayUrl() points at the server, emitted events are forwarded to
 * POST /api/events/publish so SSE subscribers see agent-side activity.
 * The server process itself must NOT set a relay URL (it would feed back).
 *
 * Event Types:
 * - state: Session/connection state changes
 * - audio_level: Real-time audio energy levels (sampled in relay)
 * - transcript: User and agent transcripts
 * - tool_call: Tool invocation details
 * - approval_request: Dangerous tool approval requests (real queue id)
 * - approval_resolved: Approval decision (approve/deny/timeout)
 * - tool_result: Tool execution results
 */

import EventEmitter from 'events';

class AssistantEventEmitter extends EventEmitter {
  constructor() {
    super();
    this.setMaxListeners(50); // Support multiple concurrent clients
  }

  #emit(type, data) {
    const event = { type, timestamp: new Date().toISOString(), data };
    this.emit('event', event);
    relayEvent(event);
    return event;
  }

  /**
   * Emit state change event
   * @param {string} state - Current state (connecting, ready, recording, error, etc.)
   * @param {Object} details - Additional state details
   */
  emitState(state, details = {}) {
    return this.#emit('state', { state, ...details });
  }

  /**
   * Emit audio level event
   * @param {number} level - Audio energy level (RMS)
   * @param {boolean} isSpeech - Whether speech is detected
   */
  emitAudioLevel(level, isSpeech = false) {
    return this.#emit('audio_level', { level, isSpeech });
  }

  /**
   * Emit transcript event
   * @param {string} speaker - 'user' or 'agent'
   * @param {string} text - Transcript text
   * @param {boolean} isDelta - Whether this is a partial update
   */
  emitTranscript(speaker, text, isDelta = false) {
    return this.#emit('transcript', { speaker, text, isDelta });
  }

  /**
   * Emit tool call event
   * @param {string} toolName - Name of the tool being called
   * @param {Object} args - Tool arguments
   * @param {string} callId - Unique call identifier
   */
  emitToolCall(toolName, args, callId) {
    return this.#emit('tool_call', { toolName, args, callId });
  }

  /**
   * Emit approval request event
   * @param {string} toolName - Name of the tool requiring approval
   * @param {Object} args - Tool arguments
   * @param {string} approvalId - The REAL pending-approval id (resolveable via /api/approvals/:id)
   */
  emitApprovalRequest(toolName, args, approvalId) {
    return this.#emit('approval_request', { toolName, args, approvalId });
  }

  /**
   * Emit approval resolution event
   * @param {string} approvalId - The approval id that was resolved
   * @param {Object} outcome - { tool, approved, note }
   */
  emitApprovalResolved(approvalId, { tool, approved, note } = {}) {
    return this.#emit('approval_resolved', { approvalId, tool, approved, note });
  }

  /**
   * Emit tool result event
   * @param {string} toolName - Name of the tool that was executed
   * @param {*} result - Tool execution result
   * @param {string} callId - Unique call identifier
   * @param {boolean} success - Whether execution succeeded
   */
  emitToolResult(toolName, result, callId, success = true) {
    return this.#emit('tool_result', { toolName, result, callId, success });
  }

  /**
   * Emit error event
   * @param {string} source - Source of the error
   * @param {Error} error - Error object
   */
  emitError(source, error) {
    return this.#emit('error', {
      source,
      message: error?.message || String(error),
      stack: error?.stack,
    });
  }

  /**
   * Forward an event received from the relay endpoint into the local stream.
   * Used by the server to re-publish agent-process events to SSE clients.
   * @param {Object} event - { type, timestamp, data }
   */
  forward(event) {
    this.emit('event', {
      type: String(event.type),
      timestamp: event.timestamp || new Date().toISOString(),
      data: event.data ?? {},
    });
  }

  /**
   * Get event stream for SSE (Server-Sent Events)
   * @returns {AsyncGenerator} Generator that yields SSE-formatted events
   */
  async *getEventStream() {
    const listener = (event) => {
      this._queueEvent(event);
    };

    this.on('event', listener);

    try {
      while (true) {
        const event = await this._getNextEvent();
        yield `data: ${JSON.stringify(event)}\n\n`;
      }
    } finally {
      this.off('event', listener);
    }
  }

  _eventQueue = [];
  _eventResolvers = [];

  _queueEvent(event) {
    if (this._eventResolvers.length > 0) {
      const resolve = this._eventResolvers.shift();
      resolve(event);
    } else {
      this._eventQueue.push(event);
    }
  }

  _getNextEvent() {
    if (this._eventQueue.length > 0) {
      return Promise.resolve(this._eventQueue.shift());
    }
    return new Promise((resolve) => {
      this._eventResolvers.push(resolve);
    });
  }
}

// ---------- Cross-process relay ----------
// Batches events and POSTs them to the server's /api/events/publish.
// audio_level arrives at ~32 events/s — it is thinned on flush so the
// SSE channel and dashboards get a smooth sample instead of a flood.
const RELAY_FLUSH_MS = 150;
const MAX_AUDIO_PER_FLUSH = 4;
const MAX_QUEUED_EVENTS = 200;
const MAX_RELAY_BYTES = 64 * 1024;

let relayUrl = null;
let relayQueue = [];
let relayTimer = null;
let relayFailures = 0;

export function setRelayUrl(url) {
  relayUrl = url || null;
  if (!relayUrl && relayTimer) {
    clearTimeout(relayTimer);
    relayTimer = null;
    relayQueue = [];
  }
}

export function getRelayUrl() {
  return relayUrl;
}

function relayEvent(event) {
  if (!relayUrl) return;
  relayQueue.push(event);
  // Backpressure: drop oldest rather than growing unbounded
  while (relayQueue.length > MAX_QUEUED_EVENTS) relayQueue.shift();
  if (!relayTimer) {
    relayTimer = setTimeout(flushRelay, RELAY_FLUSH_MS);
    if (relayTimer.unref) relayTimer.unref();
  }
}

async function flushRelay() {
  relayTimer = null;
  if (!relayUrl || relayQueue.length === 0) return;
  const batch = relayQueue;
  relayQueue = [];

  // Thin audio_level to the most recent sample burst; other types keep order.
  const audio = batch.filter((e) => e.type === 'audio_level');
  let payload = batch;
  if (audio.length > MAX_AUDIO_PER_FLUSH) {
    const keptAudio = new Set(audio.slice(-MAX_AUDIO_PER_FLUSH));
    payload = batch.filter((e) => e.type !== 'audio_level' || keptAudio.has(e));
  }

  // Payload cap: drop oldest oversized events rather than failing the batch.
  while (payload.length > 1 && JSON.stringify(payload).length > MAX_RELAY_BYTES) {
    payload.shift();
  }
  if (JSON.stringify(payload).length > MAX_RELAY_BYTES) {
    payload = [{ ...payload[0], data: { ...payload[0].data, args: '[omitted: too large]' } }];
  }

  try {
    const res = await fetch(`${relayUrl}/api/events/publish`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', 'X-Requested-With': 'pc-assistant-agent' },
      body: JSON.stringify({ events: payload }),
    });
    if (!res.ok) throw new Error(`relay responded ${res.status}`);
    relayFailures = 0;
  } catch (err) {
    relayFailures++;
    // Live events: stale redelivery is worse than loss, so the batch is dropped.
    if (relayFailures === 1 || relayFailures % 50 === 0) {
      console.warn(`[events] relay to ${relayUrl} unavailable (${relayFailures} failed flushes): ${err.message}`);
    }
  }
}

// Global singleton instance
export const eventEmitter = new AssistantEventEmitter();
export default eventEmitter;
