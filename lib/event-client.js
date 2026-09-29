/**
 * Event Client for SSE Connection
 * 
 * Provides a simple interface to connect to the server's SSE endpoint
 * and receive real-time events from the voice agent.
 */

import EventEmitter from 'events';

export function createEventStream(serverUrl = 'http://localhost:3000') {
  const emitter = new EventEmitter();
  let abortController = null;
  let reconnectTimeout = null;

  async function connect() {
    try {
      abortController = new AbortController();
      
      const response = await fetch(`${serverUrl}/api/events`, {
        signal: abortController.signal
      });

      if (!response.ok) {
        throw new Error(`HTTP ${response.status}: ${response.statusText}`);
      }

      const reader = response.body.getReader();
      const decoder = new TextDecoder();
      let buffer = '';

      emitter.emit('connected');

      while (true) {
        const { done, value } = await reader.read();
        if (done) break;

        buffer += decoder.decode(value, { stream: true });
        const lines = buffer.split('\n');
        buffer = lines.pop() || ''; // Keep incomplete line in buffer

        for (const line of lines) {
          if (line.startsWith('data: ')) {
            try {
              const event = JSON.parse(line.substring(6));
              emitter.emit('event', event);
            } catch (e) {
              emitter.emit('error', new Error(`Failed to parse event: ${e.message}`));
            }
          }
        }
      }
    } catch (error) {
      if (error.name === 'AbortError') {
        emitter.emit('disconnected');
        return;
      }

      emitter.emit('error', error);
      
      // Auto-reconnect after 5 seconds
      reconnectTimeout = setTimeout(() => {
        emitter.emit('reconnecting');
        connect();
      }, 5000);
    }
  }

  function close() {
    if (abortController) {
      abortController.abort();
    }
    if (reconnectTimeout) {
      clearTimeout(reconnectTimeout);
    }
    emitter.emit('disconnected');
  }

  // Start connection
  connect();

  return {
    on: (event, callback) => emitter.on(event, callback),
    off: (event, callback) => emitter.off(event, callback),
    close,
    emitter
  };
}