// Security configuration and confirmation gates
import { SHELL_META_PATTERN } from './tools/shell-control.js';
import { appendSecurityAudit } from './lib/store.js';

// Tools that require explicit user confirmation before execution
const DANGEROUS_TOOLS = [
  'move_mouse',
  'click_mouse',
  'type_text',
  'press_keys',
  'kill_process',
  'run_command',
  'send_email',
  'create_event',
  'open_application',
  'computer_use',
  'run_workflow',
  'terminal_execute',
  'terminal_start',
  'execute_plan',
  'spawn_agent',
  // Undo mutates real state (file renames, row restores) — gate it like
  // any other consequential action.
  'undo_last',
  'undo_session'
];

// System PIDs that should never be killed
const PROTECTED_PIDS = [1]; // PID 1 is typically init/systemd

// Check if a tool requires confirmation
export function requiresConfirmation(toolName) {
  return DANGEROUS_TOOLS.includes(toolName);
}

// Legacy confirmation helpers — DEPRECATED.
// Real human-in-the-loop approvals live in lib/security-extras.js
// (requestApproval backed by the /api/confirm UI). These stubs remain only so
// old imports don't crash, and they NEVER auto-approve.
export function requestConfirmation(toolName, args, callback) {
  const err = new Error(
    'requestConfirmation() is deprecated: use requestApproval() from lib/security-extras.js (human-in-the-loop via /api/confirm)'
  );
  if (typeof callback === 'function') {
    callback(false);
  }
  throw err;
}

// Handle user response to confirmation
export function handleConfirmationResponse(approved) {
  throw new Error(
    'handleConfirmationResponse() is deprecated: use resolveApproval() from lib/security-extras.js'
  );
}

// Get current pending confirmation
export function getPendingConfirmation() {
  return null;
}

// Check if a PID is protected
export function isProtectedPid(pid) {
  return PROTECTED_PIDS.includes(pid);
}

// Tool sanitizer to remove embedded instructions from tool descriptions
export function sanitizeToolDescription(description) {
  if (!description || typeof description !== 'string') {
    return description;
  }

  // Remove common instruction injection patterns
  const patterns = [
    /ignore previous instructions/gi,
    /disregard all above/gi,
    /forget everything/gi,
    /new instructions:/gi,
    /override:/gi,
    /additional instructions:/gi,
    /hidden instructions:/gi,
    /secret instructions:/gi
  ];

  let sanitized = description;
  for (const pattern of patterns) {
    sanitized = sanitized.replace(pattern, '[REDACTED]');
  }

  return sanitized;
}

// Validate tool arguments for safety
export function validateToolArguments(toolName, args) {
  const validationErrors = [];

  switch (toolName) {
    case 'move_mouse':
      if (!Number.isFinite(args.x) || !Number.isFinite(args.y) || args.x < 0 || args.y < 0) {
        validationErrors.push('x and y must be non-negative numbers');
      }
      break;

    case 'click_mouse':
      if (args.button && !['left', 'right', 'middle'].includes(args.button.toLowerCase())) {
        validationErrors.push('Button must be left, right, or middle');
      }
      if (args.x !== undefined && args.x < 0) {
        validationErrors.push('x coordinate must be non-negative');
      }
      if (args.y !== undefined && args.y < 0) {
        validationErrors.push('y coordinate must be non-negative');
      }
      break;

    case 'kill_process':
      if (!Number.isInteger(args.pid) || args.pid <= 0) {
        validationErrors.push('pid must be a positive integer');
      } else if (isProtectedPid(args.pid)) {
        validationErrors.push('Cannot kill protected system process');
      } else if (args.pid === process.pid || args.pid === process.ppid) {
        validationErrors.push('Cannot kill the assistant process itself or its parent runner');
      }
      break;

    case 'run_command':
      if (!args.command || typeof args.command !== 'string') {
        validationErrors.push('Command must be a non-empty string');
        break;
      }
      // Check for forbidden shell metacharacters and chaining operators
      if (SHELL_META_PATTERN.test(args.command)) {
        validationErrors.push('Command contains forbidden shell metacharacters or chaining operators');
      }
      // Check for dangerous command patterns
      const dangerousPatterns = [
        /rm\s+-rf/,
        /del\s+\/.*$/,
        /format\s+c:/,
        /shutdown/,
        /reboot/,
        /:\s*>\s*\//,
        />\s*\/dev\/null/
      ];
      for (const pattern of dangerousPatterns) {
        if (pattern.test(args.command)) {
          validationErrors.push(`Command contains dangerous pattern: ${pattern}`);
        }
      }
      if (args.cwd !== undefined && args.cwd !== null && typeof args.cwd !== 'string') {
        validationErrors.push('cwd must be a string path');
      }
      if (args.timeoutMs !== undefined && args.timeoutMs !== null) {
        const t = Number(args.timeoutMs);
        if (!Number.isFinite(t) || t < 1000 || t > 120000) {
          validationErrors.push('timeoutMs must be between 1000 and 120000');
        }
      }
      break;

    case 'terminal_start':
      if (!args.command || typeof args.command !== 'string' || !args.command.trim()) {
        validationErrors.push('command must be a non-empty string');
        break;
      }
      if (SHELL_META_PATTERN.test(args.command)) {
        validationErrors.push('Command contains forbidden shell metacharacters or chaining operators');
      }
      if (args.cwd !== undefined && args.cwd !== null && typeof args.cwd !== 'string') {
        validationErrors.push('cwd must be a string path');
      }
      break;

    case 'terminal_execute':
      if (!args.command || typeof args.command !== 'string') {
        validationErrors.push('Command must be a non-empty string');
        break;
      }
      if (SHELL_META_PATTERN.test(args.command)) {
        validationErrors.push('Command contains forbidden shell metacharacters or chaining operators');
      }
      if (args.cwd !== undefined && args.cwd !== null && typeof args.cwd !== 'string') {
        validationErrors.push('cwd must be a string path');
      }
      if (args.timeoutMs !== undefined && args.timeoutMs !== null) {
        const t = Number(args.timeoutMs);
        if (!Number.isFinite(t) || t < 1000 || t > 120000) {
          validationErrors.push('timeoutMs must be between 1000 and 120000');
        }
      }
      break;

    case 'terminal_read':
    case 'terminal_kill':
      if (!args.sessionId || typeof args.sessionId !== 'string' || !args.sessionId.trim()) {
        validationErrors.push('sessionId must be a non-empty string');
      }
      break;

    case 'terminal_input':
      if (!args.sessionId || typeof args.sessionId !== 'string' || !args.sessionId.trim()) {
        validationErrors.push('sessionId must be a non-empty string');
      } else if (typeof args.input !== 'string' || args.input.length === 0) {
        validationErrors.push('input must be a non-empty string');
      } else if (Buffer.byteLength(args.input) > 10240) {
        validationErrors.push('input exceeds safety limit (10240 bytes)');
      }
      break;

    case 'send_email':
      if (!args.to || !isValidEmail(args.to)) {
        validationErrors.push('Invalid recipient email address');
      }
      break;

    case 'type_text':
      if (typeof args.text !== 'string' || args.text.length === 0) {
        validationErrors.push('text must be a non-empty string');
      } else if (args.text.length > 10000) {
        validationErrors.push('Text length exceeds safety limit (10000 characters)');
      }
      break;

    case 'press_keys':
      if (!args.keys || typeof args.keys !== 'string' || !args.keys.trim()) {
        validationErrors.push('keys must be a non-empty string (e.g. "ctrl+c", "enter")');
      } else if (args.keys.length > 100) {
        validationErrors.push('keys exceeds safety limit (100 characters)');
      } else {
        const parts = args.keys.toLowerCase().split('+').map((s) => s.trim());
        if (parts.some((p) => !p || !/^[a-z0-9]+$/.test(p))) {
          validationErrors.push('keys contains invalid key names (use letters/numbers joined by "+")');
        } else if (parts.length > 4) {
          validationErrors.push('keys chord has too many parts (max 4)');
        }
      }
      break;

    case 'computer_use':
      if (!args.task || typeof args.task !== 'string' || !args.task.trim()) {
        validationErrors.push('task must be a non-empty string (e.g. "Open Google Chrome")');
      } else if (args.task.length > 2000) {
        validationErrors.push('task exceeds safety limit (2000 characters)');
      }
      if (args.environment !== undefined && !['desktop', 'browser'].includes(String(args.environment).toLowerCase())) {
        validationErrors.push('environment must be "desktop" or "browser"');
      }
      break;

    case 'open_application':
      if (!args.appName || typeof args.appName !== 'string') {
        validationErrors.push('appName must be a non-empty string');
      } else if (!/^[a-zA-Z0-9_.:\- ]+$/.test(args.appName.trim())) {
        validationErrors.push('appName contains invalid characters');
      }
      break;

    case 'manage_windows':
      if (!args.action || !['minimize_all', 'restore_all', 'switch_to', 'close'].includes(String(args.action).toLowerCase())) {
        validationErrors.push('action must be minimize_all, restore_all, switch_to, or close');
      } else if (['switch_to', 'close'].includes(String(args.action).toLowerCase()) && (!args.target || typeof args.target !== 'string' || !args.target.trim())) {
        validationErrors.push(`target is required when action is "${args.action}"`);
      }
      break;

    case 'media_control':
      if (!args.action || !['volume_up', 'volume_down', 'mute', 'unmute', 'toggle_mute', 'play_pause', 'play', 'pause', 'next_track', 'next', 'previous_track', 'previous', 'prev'].includes(String(args.action).toLowerCase())) {
        validationErrors.push('Invalid media action');
      }
      break;

    case 'remember':
      if (!args.key || typeof args.key !== 'string' || !args.key.trim()) {
        validationErrors.push('key must be a non-empty string');
      } else if (args.key.trim().length > 200) {
        validationErrors.push('key exceeds safety limit (200 characters)');
      }
      if (typeof args.value !== 'string' || args.value.length === 0) {
        validationErrors.push('value must be a non-empty string');
      } else if (args.value.length > 4000) {
        validationErrors.push('value exceeds safety limit (4000 characters)');
      }
      if (args.category !== undefined && !['preference', 'location', 'project', 'workflow', 'fact'].includes(String(args.category).toLowerCase())) {
        validationErrors.push('category must be preference, location, project, workflow, or fact');
      }
      break;

    case 'recall':
      if (args.query !== undefined && typeof args.query !== 'string') {
        validationErrors.push('query must be a string');
      } else if (typeof args.query === 'string' && args.query.length > 500) {
        validationErrors.push('query exceeds safety limit (500 characters)');
      }
      if (args.category !== undefined && args.category !== null && !['preference', 'location', 'project', 'workflow', 'fact'].includes(String(args.category).toLowerCase())) {
        validationErrors.push('category must be preference, location, project, workflow, or fact');
      }
      break;

    case 'forget':
    case 'delete_workflow':
      if (!args.key && !args.name) {
        validationErrors.push('key (forget) or name (delete_workflow) is required');
      }
      break;

    case 'resolve_location':
      if (!args.name || typeof args.name !== 'string' || !args.name.trim()) {
        validationErrors.push('name must be a non-empty string');
      }
      break;

    case 'save_workflow':
      if (!args.name || typeof args.name !== 'string' || !args.name.trim()) {
        validationErrors.push('name must be a non-empty string');
      } else if (!/^[a-zA-Z0-9 _-]{1,80}$/.test(args.name.trim())) {
        validationErrors.push('name may only contain letters, numbers, spaces, _ and - (max 80)');
      }
      if (!Array.isArray(args.steps) || args.steps.length === 0 || args.steps.length > 50) {
        validationErrors.push('steps must be a non-empty array (max 50)');
      }
      break;

    case 'run_workflow':
      if (!args.name || typeof args.name !== 'string' || !args.name.trim()) {
        validationErrors.push('name must be a non-empty string');
      }
      break;

    case 'plan_task':
      if (!args.goal || typeof args.goal !== 'string' || !args.goal.trim()) {
        validationErrors.push('goal must be a non-empty string');
      } else if (args.goal.length > 2000) {
        validationErrors.push('goal exceeds safety limit (2000 characters)');
      }
      if (args.steps !== undefined && (!Array.isArray(args.steps) || args.steps.length === 0 || args.steps.length > 30)) {
        validationErrors.push('steps must be a non-empty array (max 30)');
      }
      break;

    case 'execute_plan':
    case 'plan_status':
    case 'cancel_plan':
      if (!args.planId || typeof args.planId !== 'string' || !args.planId.trim()) {
        validationErrors.push('planId must be a non-empty string');
      } else if (!/^plan-[a-z0-9]+$/i.test(args.planId.trim())) {
        validationErrors.push('planId must look like plan-<id>');
      }
      break;

    case 'spawn_agent':
      if (!args.role || typeof args.role !== 'string' || !args.role.trim()) {
        validationErrors.push('role must be a non-empty string');
      } else if (args.role.length > 200) {
        validationErrors.push('role exceeds safety limit (200 characters)');
      }
      if (args.instructions !== undefined && typeof args.instructions !== 'string') {
        validationErrors.push('instructions must be a string');
      } else if (typeof args.instructions === 'string' && args.instructions.length > 4000) {
        validationErrors.push('instructions exceed safety limit (4000 characters)');
      }
      if (!Array.isArray(args.allowed_tools) || args.allowed_tools.length === 0 || args.allowed_tools.length > 40) {
        validationErrors.push('allowed_tools must be a non-empty array (max 40, deny-by-default)');
      } else if (args.allowed_tools.some((t) => typeof t !== 'string' || !t.trim())) {
        validationErrors.push('allowed_tools must contain only non-empty strings');
      }
      if (args.isolation !== undefined && !['auto', 'shared', 'spawned'].includes(String(args.isolation).toLowerCase())) {
        validationErrors.push('isolation must be "auto", "shared", or "spawned"');
      }
      if (args.max_steps !== undefined && args.max_steps !== null) {
        const n = Number(args.max_steps);
        if (!Number.isFinite(n) || n < 1 || n > 50) {
          validationErrors.push('max_steps must be between 1 and 50');
        }
      }
      if (args.timeoutMs !== undefined && args.timeoutMs !== null) {
        const t = Number(args.timeoutMs);
        if (!Number.isFinite(t) || t < 1000 || t > 1800000) {
          validationErrors.push('timeoutMs must be between 1000 and 1800000');
        }
      }
      break;

    case 'agent_status':
    case 'cancel_agent':
      if (!args.agentId || typeof args.agentId !== 'string' || !args.agentId.trim()) {
        validationErrors.push('agentId must be a non-empty string');
      } else if (!/^agent-[a-z0-9]+$/i.test(args.agentId.trim())) {
        validationErrors.push('agentId must look like agent-<id>');
      }
      break;

    case 'send_to_agent':
      if (!args.agentId || typeof args.agentId !== 'string' || !args.agentId.trim()) {
        validationErrors.push('agentId must be a non-empty string');
      } else if (!/^agent-[a-z0-9]+$/i.test(args.agentId.trim())) {
        validationErrors.push('agentId must look like agent-<id>');
      }
      if (!args.text || typeof args.text !== 'string' || !args.text.trim()) {
        validationErrors.push('text must be a non-empty string');
      } else if (args.text.length > 2000) {
        validationErrors.push('text exceeds safety limit (2000 characters)');
      }
      break;

    case 'clipboard':
      if (!args.action || !['read', 'write'].includes(String(args.action).toLowerCase())) {
        validationErrors.push('action must be "read" or "write"');
      }
      if (args.action === 'write' && typeof args.text !== 'string') {
        validationErrors.push('text must be provided when action is write');
      }
      break;
  }

  return validationErrors;
}

// Forbidden shell metacharacters — imported at module top from
// tools/shell-control.js (canonical definition).

// Simple email validation
function isValidEmail(email) {
  const emailRegex = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;
  return emailRegex.test(email);
}

// Security audit logging — console + DuckDB security_audit table (best-effort).
export async function logSecurityEvent(event, details) {
  const logEntry = {
    timestamp: new Date().toISOString(),
    event: event,
    details: details,
    severity: getEventSeverity(event)
  };

  console.log(`[SECURITY] ${event}: ${JSON.stringify(details)}`);

  try {
    await appendSecurityAudit(logEntry);
  } catch {
    // Logging must never break tool execution
  }
}

function getEventSeverity(event) {
  const highSeverityEvents = [
    'UNAUTHORIZED_ACCESS_ATTEMPT',
    'DANGEROUS_TOOL_EXECUTION',
    'PROTECTED_PID_ACCESS',
    'COMMAND_INJECTION_ATTEMPT',
    'CONFIRMATION_BYPASS'
  ];

  const mediumSeverityEvents = [
    'TOOL_EXECUTION',
    'CONFIRMATION_REQUESTED',
    'ARGUMENT_VALIDATION_FAILED'
  ];

  if (highSeverityEvents.includes(event)) {
    return 'HIGH';
  } else if (mediumSeverityEvents.includes(event)) {
    return 'MEDIUM';
  } else {
    return 'LOW';
  }
}

// Rate limiting for dangerous operations
const rateLimiter = {
  counts: {},
  windowMs: 60000, // 1 minute window
  maxRequests: 10  // Max 10 dangerous operations per minute
};

export function checkRateLimit(toolName) {
  const now = Date.now();
  const key = toolName;

  // Clean old entries
  if (!rateLimiter.counts[key] || rateLimiter.counts[key].timestamp < now - rateLimiter.windowMs) {
    rateLimiter.counts[key] = {
      count: 0,
      timestamp: now
    };
  }

  // Prune stale entries if map accumulates many keys
  const keys = Object.keys(rateLimiter.counts);
  if (keys.length > 50) {
    const cutoff = now - rateLimiter.windowMs;
    for (const k of keys) {
      if (rateLimiter.counts[k].timestamp < cutoff) {
        delete rateLimiter.counts[k];
      }
    }
  }

  rateLimiter.counts[key].count++;

  if (rateLimiter.counts[key].count > rateLimiter.maxRequests) {
    return false;
  }

  return true;
}

export function resetRateLimit(toolName) {
  delete rateLimiter.counts[toolName];
}