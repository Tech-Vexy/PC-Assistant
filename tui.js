/**
 * Simple Console UI for PC Assistant
 * 
 * A lightweight console interface for real-time monitoring
 * of voice agent activities.
 * 
 * Features:
 * - Transcript showing user/agent conversation
 * - Tool call monitoring
 * - Audio level visualization
 * - Status indicators
 */

import { createEventStream } from './lib/event-client.js';

class ConsoleTUI {
  constructor() {
    this.transcript = [];
    this.toolCalls = [];
    this.audioLevels = [];
    this.maxAudioLevels = 30;
    this.currentStatus = 'Disconnected';
    
    this.setupEventStream();
  }

  setupEventStream() {
    this.eventStream = createEventStream();
    
    this.eventStream.on('connected', () => {
      console.log('✅ Connected to event stream');
    });

    this.eventStream.on('event', (event) => {
      this.handleEvent(event);
    });

    this.eventStream.on('error', (error) => {
      console.error('❌ Event stream error:', error.message);
    });

    this.eventStream.on('reconnecting', () => {
      console.log('🔄 Reconnecting to event stream...');
    });

    this.eventStream.on('disconnected', () => {
      console.log('🔌 Disconnected from event stream');
    });
  }

  handleEvent(event) {
    switch (event.type) {
      case 'state':
        this.updateStatus(event.data.state);
        break;
      case 'transcript':
        this.addTranscript(event.data);
        break;
      case 'tool_call':
        this.addToolCall(event.data);
        break;
      case 'tool_result':
        this.addToolResult(event.data);
        break;
      case 'audio_level':
        this.updateAudioLevel(event.data);
        break;
      case 'approval_request':
        this.addApprovalRequest(event.data);
        break;
      case 'approval_resolved':
        this.showApprovalResolved(event.data);
        break;
      case 'error':
        this.showError(event.data);
        break;
    }
  }

  updateStatus(state) {
    const statusMap = {
      'connected': '🟢 Connected',
      'ready': '🟢 Ready',
      'recording': '🔴 Recording',
      'resuming': '🟡 Resuming',
      'initializing': '🟡 Initializing',
      'error': '🔴 Error'
    };
    this.currentStatus = statusMap[state] || state;
    this.render();
  }

  addTranscript(data) {
    const { speaker, text, isDelta } = data;
    const prefix = speaker === 'user' ? '👤 You: ' : '🤖 AI: ';
    
    if (isDelta) {
      // Append to last transcript
      if (this.transcript.length > 0) {
        this.transcript[this.transcript.length - 1].text += text;
      }
    } else {
      this.transcript.push({ speaker, text, timestamp: new Date() });
    }
    
    // Keep only last 20 transcripts
    if (this.transcript.length > 20) {
      this.transcript.shift();
    }
    
    this.render();
  }

  addToolCall(data) {
    const { toolName, args, callId } = data;
    this.toolCalls.push({
      toolName,
      args,
      callId,
      timestamp: new Date(),
      status: 'running'
    });
    
    // Keep only last 10 tool calls
    if (this.toolCalls.length > 10) {
      this.toolCalls.shift();
    }
    
    this.render();
  }

  addToolResult(data) {
    const { toolName, success } = data;
    const call = this.toolCalls.find(c => c.toolName === toolName && c.status === 'running');
    if (call) {
      call.status = success ? 'completed' : 'failed';
    }
    this.render();
  }

  addApprovalRequest(data) {
    const { toolName, approvalId } = data;
    console.log(`\n🔒 APPROVAL NEEDED: ${toolName}`);
    console.log(`   ID: ${approvalId}`);
    console.log(`   Visit http://localhost:3000/api/confirm to approve`);
    this.render();
  }

  showApprovalResolved(data) {
    const { tool, approved, note } = data;
    const mark = approved ? '✅ APPROVED' : '❌ DENIED';
    console.log(`\n${mark}: ${tool || 'unknown'}${note ? ` — ${note}` : ''}`);
    this.render();
  }

  updateAudioLevel(data) {
    const { level, isSpeech } = data;
    this.audioLevels.push({ level, isSpeech });
    
    if (this.audioLevels.length > this.maxAudioLevels) {
      this.audioLevels.shift();
    }
    
    this.render();
  }

  showError(data) {
    const { source, message } = data;
    console.error(`\n❌ Error in ${source}: ${message}`);
  }

  render() {
    // Clear screen and render
    console.clear();
    
    // Header
    console.log('═══════════════════════════════════════════════════════════════');
    console.log(`       PC Assistant Monitor | Status: ${this.currentStatus}`);
    console.log('═══════════════════════════════════════════════════════════════');
    
    // Audio visualization
    console.log('\n📊 Audio Level:');
    const waveform = this.audioLevels.map(({ level, isSpeech }) => {
      const normalized = Math.min(Math.floor(level / 1000), 20);
      const bar = '█'.repeat(normalized);
      return isSpeech ? `🟢 ${bar}` : `⚪ ${bar}`;
    }).join('');
    console.log(waveform || 'No audio data');
    
    // Recent transcript
    console.log('\n💬 Recent Transcript:');
    if (this.transcript.length === 0) {
      console.log('  No conversation yet...');
    } else {
      this.transcript.slice(-5).forEach(({ speaker, text }) => {
        const prefix = speaker === 'user' ? '👤' : '🤖';
        console.log(`  ${prefix} ${text.substring(0, 80)}${text.length > 80 ? '...' : ''}`);
      });
    }
    
    // Active tool calls
    console.log('\n🔧 Active Tool Calls:');
    const activeCalls = this.toolCalls.filter(c => c.status === 'running');
    if (activeCalls.length === 0) {
      console.log('  No active tools');
    } else {
      activeCalls.forEach(({ toolName, args }) => {
        console.log(`  • ${toolName}`);
        console.log(`    Args: ${JSON.stringify(args).substring(0, 60)}...`);
      });
    }
    
    // Footer
    console.log('\n═══════════════════════════════════════════════════════════════');
    console.log('Press Ctrl+C to exit | Visit http://localhost:3000/setup for config');
  }

  close() {
    this.eventStream.close();
  }
}

// Start TUI if run directly
if (process.argv[1] && process.argv[1].endsWith('tui.js')) {
  const tui = new ConsoleTUI();
  
  process.on('SIGINT', () => {
    tui.close();
    console.log('\n👋 Goodbye!');
    process.exit(0);
  });
  
  console.log('🚀 Starting PC Assistant Monitor...');
}

export { ConsoleTUI };