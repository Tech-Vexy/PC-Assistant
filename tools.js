import {
  requiresConfirmation,
  validateToolArguments,
  sanitizeToolDescription,
  logSecurityEvent,
  checkRateLimit
} from './security.js';

import {
  verifyScreenBeforeControl,
  requestApproval,
} from './lib/security-extras.js';

import { appendToolAudit, cfg, undoRecord, undoList, undoMarkDone } from './lib/store.js';
import { getPerformanceMonitor, createLogger } from './lib/monitor.js';
import { captureBefore, captureAfter, applyRecord } from './lib/undo.js';

const logger = createLogger('tool-dispatcher');
const perfMonitor = getPerformanceMonitor();

// Undo/transaction journaling (vision item #2). Workflow/plan runners wrap
// their nested dispatches with setNestedUndoContext so journal rows carry the
// owning plan/workflow identity and "undo the whole plan" can find them.
let nestedUndoContext = null;
export function setNestedUndoContext(ctx) {
  nestedUndoContext = ctx;
}

// Import tool handlers
import { webSearch } from './tools/search-mcp.js';
import { moveMouse, clickMouse, typeText, pressKeys } from './tools/device-control.js';
import { systemStatus, listProcesses, killProcess } from './tools/system-monitor.js';
import { runCommand } from './tools/shell-control.js';
import { openApplication, manageWindows, mediaControl, clipboardControl, listInstalledApps } from './tools/desktop-suite.js';
import { organizeFolder, renameFiles, findFiles, convertDocument } from './tools/file-manager.js';
import { runComputerUseTask } from './computer-use/dispatch.js';
import {
  rememberMemory,
  recallMemory,
  forgetMemory,
  resolvePlace,
  saveWorkflow,
  listWorkflows,
  deleteWorkflow,
  runWorkflow,
} from './tools/memory.js';
import {
  terminalExecute,
  terminalStart,
  terminalRead,
  terminalInput,
  terminalKill,
} from './tools/terminal.js';
import {
  planTask,
  planStatus,
  listPlans,
  cancelPlan,
  executePlan,
} from './tools/plan.js';
import {
  spawnAgent,
  listAgents,
  agentStatus,
  cancelAgent,
  sendToAgent,
} from './tools/agents.js';
import { playEarcon } from './lib/sound-effects.js';

// Tool definitions for AssemblyAI agent (with sanitized descriptions)
export const toolDefinitions = [
  {
    name: 'web_search',
    description: sanitizeToolDescription('Search the web for real-time information with Google Search'),
    parameters: {
      type: 'object',
      properties: {
        query: {
          type: 'string',
          description: 'The search query'
        },
        maxResults: {
          type: 'number',
          description: 'Maximum number of results to return (default: 5)',
          default: 5
        }
      },
      required: ['query']
    }
  },
  {
    name: 'move_mouse',
    description: sanitizeToolDescription('Move the mouse cursor to specific screen coordinates'),
    parameters: {
      type: 'object',
      properties: {
        x: {
          type: 'number',
          description: 'X coordinate'
        },
        y: {
          type: 'number',
          description: 'Y coordinate'
        }
      },
      required: ['x', 'y']
    }
  },
  {
    name: 'click_mouse',
    description: sanitizeToolDescription('Click, double click, or right click the mouse at the current position or specified coordinates'),
    parameters: {
      type: 'object',
      properties: {
        button: {
          type: 'string',
          description: 'Mouse button to click: "left", "right", or "middle" (default: "left")'
        },
        double: {
          type: 'boolean',
          description: 'Whether to double click (default: false)'
        },
        x: {
          type: 'number',
          description: 'Optional X coordinate to move to before clicking'
        },
        y: {
          type: 'number',
          description: 'Optional Y coordinate to move to before clicking'
        }
      }
    }
  },
  {
    name: 'type_text',
    description: sanitizeToolDescription('Type text at the current cursor position'),
    parameters: {
      type: 'object',
      properties: {
        text: {
          type: 'string',
          description: 'Text to type'
        }
      },
      required: ['text']
    }
  },
  {
    name: 'press_keys',
    description: sanitizeToolDescription('Press keyboard keys or shortcuts'),
    parameters: {
      type: 'object',
      properties: {
        keys: {
          type: 'string',
          description: 'Keys to press (e.g., "ctrl+c", "enter", "alt+tab")'
        }
      },
      required: ['keys']
    }
  },
  {
    name: 'system_status',
    description: sanitizeToolDescription('Get current system status (CPU, memory, disk, network)'),
    parameters: {
      type: 'object',
      properties: {},
      required: []
    }
  },
  {
    name: 'list_processes',
    description: sanitizeToolDescription('List running processes (optionally filtered by name)'),
    parameters: {
      type: 'object',
      properties: {
        name: {
          type: 'string',
          description: 'Filter processes by name or substring (e.g. "calculator", "chrome")'
        },
        sortBy: {
          type: 'string',
          description: 'Sort by field (cpu, mem, pid, name)',
          default: 'cpu'
        },
        limit: {
          type: 'number',
          description: 'Maximum number of processes to return (default: 20)',
          default: 20
        }
      },
      required: []
    }
  },
  {
    name: 'kill_process',
    description: sanitizeToolDescription('Terminate a process by PID'),
    parameters: {
      type: 'object',
      properties: {
        pid: {
          type: 'number',
          description: 'Process ID to terminate'
        }
      },
      required: ['pid']
    }
  },
  {
    name: 'run_command',
    description: sanitizeToolDescription('Execute an allowlisted shell command'),
    parameters: {
      type: 'object',
      properties: {
        command: {
          type: 'string',
          description: 'Command to execute (must be in allowlist)'
        },
        cwd: {
          type: 'string',
          description: 'Working directory (must exist; defaults to the assistant directory)'
        },
        timeoutMs: {
          type: 'number',
          description: 'Timeout in ms, 1000–120000 (default 30000)',
          default: 30000
        }
      },
      required: ['command']
    }
  },
  {
    name: 'terminal_execute',
    description: sanitizeToolDescription('Run an allowlisted command and wait for it to finish (same safety rules as run_command, plus working directory and timeout). Prefer this over visually typing commands.'),
    parameters: {
      type: 'object',
      properties: {
        command: { type: 'string', description: 'Command to execute (must be in allowlist)' },
        cwd: { type: 'string', description: 'Working directory (must exist)' },
        timeoutMs: { type: 'number', description: 'Timeout in ms, 1000–120000 (default 30000)', default: 30000 }
      },
      required: ['command']
    }
  },
  {
    name: 'terminal_start',
    description: sanitizeToolDescription('Start a long-running allowlisted command as a background terminal session (dev servers, watchers, REPLs). Approved once at start; returns a sessionId for terminal_read/input/kill.'),
    parameters: {
      type: 'object',
      properties: {
        command: { type: 'string', description: 'Command to run (must be in allowlist, e.g. "npm run dev")' },
        cwd: { type: 'string', description: 'Working directory, e.g. the project folder' }
      },
      required: ['command']
    }
  },
  {
    name: 'terminal_read',
    description: sanitizeToolDescription('Read new output from a terminal session since the last read.'),
    parameters: {
      type: 'object',
      properties: {
        sessionId: { type: 'string', description: 'Session ID from terminal_start' },
        tailChars: { type: 'number', description: 'Max chars to return, 100–50000 (default 8000)', default: 8000 }
      },
      required: ['sessionId']
    }
  },
  {
    name: 'terminal_input',
    description: sanitizeToolDescription('Type text into a running terminal session stdin (commands, answers to prompts). Covered by the terminal_start approval.'),
    parameters: {
      type: 'object',
      properties: {
        sessionId: { type: 'string', description: 'Session ID from terminal_start' },
        input: { type: 'string', description: 'Text to send (include \\n for Enter). Max 10240 bytes.' }
      },
      required: ['sessionId', 'input']
    }
  },
  {
    name: 'terminal_kill',
    description: sanitizeToolDescription('Terminate a terminal session (SIGTERM, then SIGKILL fallback).'),
    parameters: {
      type: 'object',
      properties: {
        sessionId: { type: 'string', description: 'Session ID from terminal_start' }
      },
      required: ['sessionId']
    }
  },
  {
    name: 'open_application',
    description: sanitizeToolDescription('Launch an application by name (e.g. Spotify, Chrome, VS Code, Notepad, Calculator, Control Panel). Use list_installed_apps to see available applications.'),
    parameters: {
      type: 'object',
      properties: {
        appName: {
          type: 'string',
          description: 'Name of the application to open'
        }
      },
      required: ['appName']
    }
  },
  {
    name: 'list_installed_apps',
    description: sanitizeToolDescription('List installed applications on the system to help identify what apps are available to launch'),
    parameters: {
      type: 'object',
      properties: {
        limit: {
          type: 'number',
          description: 'Maximum number of applications to return (default: 50, max: 200)',
          default: 50
        }
      }
    }
  },
  {
    name: 'manage_windows',
    description: sanitizeToolDescription('Manage desktop windows: minimize all windows, restore windows, switch to an open window by name, or close an application window by name'),
    parameters: {
      type: 'object',
      properties: {
        action: {
          type: 'string',
          description: 'Window action to perform: "minimize_all", "restore_all", "switch_to", or "close"',
          enum: ['minimize_all', 'restore_all', 'switch_to', 'close']
        },
        target: {
          type: 'string',
          description: 'Application title or process name to switch to or close (required if action is "switch_to" or "close")'
        }
      },
      required: ['action']
    }
  },
  {
    name: 'media_control',
    description: sanitizeToolDescription('Control PC media playback and audio volume (volume up, volume down, mute, play/pause, next track, previous track)'),
    parameters: {
      type: 'object',
      properties: {
        action: {
          type: 'string',
          description: 'Media action: "volume_up", "volume_down", "mute", "unmute", "play_pause", "next_track", "previous_track"',
          enum: ['volume_up', 'volume_down', 'mute', 'unmute', 'play_pause', 'next_track', 'previous_track']
        },
        count: {
          type: 'number',
          description: 'Number of steps for volume adjustment (default: 1)',
          default: 1
        }
      },
      required: ['action']
    }
  },
  {
    name: 'clipboard',
    description: sanitizeToolDescription('Read text currently copied to the system clipboard or write new text to the clipboard'),
    parameters: {
      type: 'object',
      properties: {
        action: {
          type: 'string',
          description: 'Action: "read" or "write"',
          enum: ['read', 'write']
        },
        text: {
          type: 'string',
          description: 'Text content to copy to clipboard (required if action is "write")'
        }
      },
      required: ['action']
    }
  },
  {
    name: 'file_organize',
    description: sanitizeToolDescription('Organize a folder into subfolders by file-type category (images, documents, spreadsheets, etc.)'),
    parameters: {
      type: 'object',
      properties: {
        folderPath: {
          type: 'string',
          description: 'Path to the folder to organize'
        },
        dryRun: {
          type: 'boolean',
          description: 'If true, only compute moves without renaming (default: false)'
        }
      },
      required: ['folderPath']
    }
  },
  {
    name: 'file_rename',
    description: sanitizeToolDescription('Rename files in a folder using a template with {name}, {ext}, {index}, {date} placeholders'),
    parameters: {
      type: 'object',
      properties: {
        folderPath: {
          type: 'string',
          description: 'Path to the folder containing files to rename'
        },
        pattern: {
          type: 'string',
          description: 'Optional regex pattern to filter which files to rename (matches against filename)'
        },
        template: {
          type: 'string',
          description: 'Naming template with placeholders {name}, {ext}, {index}, {date} (default: keeps original name)'
        },
        dryRun: {
          type: 'boolean',
          description: 'If true, only compute new names without renaming (default: false)'
        }
      },
      required: ['folderPath']
    }
  },
  {
    name: 'file_find',
    description: sanitizeToolDescription('Find files by name pattern and/or text content under a folder (recursive, depth-limited)'),
    parameters: {
      type: 'object',
      properties: {
        folderPath: {
          type: 'string',
          description: 'Path to search within'
        },
        namePattern: {
          type: 'string',
          description: 'Optional regex pattern to match filenames against'
        },
        contentQuery: {
          type: 'string',
          description: 'Optional text content to search inside files'
        },
        maxResults: {
          type: 'number',
          description: 'Maximum number of results to return (default: 20)'
        },
        maxDepth: {
          type: 'number',
          description: 'Maximum recursion depth (default: 6)'
        }
      },
      required: ['folderPath']
    }
  },
  {
    name: 'file_convert',
    description: sanitizeToolDescription('Convert a document to another format using LibreOffice headless conversion (e.g., docx to pdf)'),
    parameters: {
      type: 'object',
      properties: {
        filePath: {
          type: 'string',
          description: 'Path to the file to convert'
        },
        targetFormat: {
          type: 'string',
          description: 'Target format extension without dot (e.g., "pdf", "docx", "txt")'
        }
      },
      required: ['filePath', 'targetFormat']
    }
  },
  {
    name: 'computer_use',
    description: sanitizeToolDescription('Control the desktop or browser to complete a UI task by seeing the screen and acting with mouse/keyboard. Use for requests like open an application, click a button, fill a form, or navigate a website when no dedicated tool fits. Prefer dedicated tools (send_email, create_event, open_application) when they match.'),
    parameters: {
      type: 'object',
      properties: {
        task: {
          type: 'string',
          description: 'The UI task to perform, e.g. "Open Google Chrome" or "Search for flights on Kayak"'
        },
        environment: {
          type: 'string',
          description: 'Where to act: "desktop" (native apps, taskbar, file manager) or "browser" (web pages in Chromium)',
          enum: ['desktop', 'browser'],
          default: 'desktop'
        }
      },
      required: ['task']
    }
  },
  {
    name: 'remember',
    description: sanitizeToolDescription('Remember a fact, preference, project location, or workflow note for later (e.g. preferred editor, where the Tafiti project lives).'),
    parameters: {
      type: 'object',
      properties: {
        key: { type: 'string', description: 'Short name, e.g. "editor" or "project:tafiti"' },
        value: { type: 'string', description: 'The remembered value, e.g. "VS Code" or "C:\\Projects\\tafiti"' },
        category: { type: 'string', description: 'One of: preference, location, project, workflow, fact', default: 'fact' }
      },
      required: ['key', 'value']
    }
  },
  {
    name: 'recall',
    description: sanitizeToolDescription('Recall stored memories by search text, optionally filtered by category. Use before asking the user for something they may already have told you.'),
    parameters: {
      type: 'object',
      properties: {
        query: { type: 'string', description: 'Search text matched against keys and values (empty returns recent)' },
        category: { type: 'string', description: 'Optional filter: preference, location, project, workflow, fact' },
        limit: { type: 'number', description: 'Max results (default 10)', default: 10 }
      },
      required: []
    }
  },
  {
    name: 'forget',
    description: sanitizeToolDescription('Delete a stored memory by key.'),
    parameters: {
      type: 'object',
      properties: {
        key: { type: 'string', description: 'The memory key to delete' }
      },
      required: ['key']
    }
  },
  {
    name: 'resolve_location',
    description: sanitizeToolDescription('Resolve a project or place alias to its saved path (e.g. "tafiti" to its folder). Teach new aliases with remember first.'),
    parameters: {
      type: 'object',
      properties: {
        name: { type: 'string', description: 'Alias to resolve, e.g. "tafiti"' }
      },
      required: ['name']
    }
  },
  {
    name: 'save_workflow',
    description: sanitizeToolDescription('Save a named multi-step workflow (ordered tool calls) for reuse, e.g. "prepare-tafiti-env". Steps are validated against known tools on save.'),
    parameters: {
      type: 'object',
      properties: {
        name: { type: 'string', description: 'Workflow name: letters, numbers, spaces, _ and - (max 80)' },
        description: { type: 'string', description: 'What the workflow does' },
        steps: {
          type: 'array',
          description: 'Ordered steps, each { tool, args }. Max 50 steps.',
          items: {
            type: 'object',
            properties: {
              tool: { type: 'string' },
              args: { type: 'object' }
            },
            required: ['tool']
          }
        }
      },
      required: ['name', 'steps']
    }
  },
  {
    name: 'list_workflows',
    description: sanitizeToolDescription('List saved workflows with descriptions and success stats.'),
    parameters: { type: 'object', properties: {}, required: [] }
  },
  {
    name: 'run_workflow',
    description: sanitizeToolDescription('Run a saved workflow step by step through the normal tool pipeline (per-step approvals still apply). Stops at the first failing step.'),
    parameters: {
      type: 'object',
      properties: {
        name: { type: 'string', description: 'Workflow name from list_workflows' }
      },
      required: ['name']
    }
  },
  {
    name: 'delete_workflow',
    description: sanitizeToolDescription('Delete a saved workflow by name.'),
    parameters: {
      type: 'object',
      properties: {
        name: { type: 'string', description: 'Workflow name to delete' }
      },
      required: ['name']
    }
  },
  {
    name: 'plan_task',
    description: sanitizeToolDescription('Decompose a goal into an executable plan (ordered tool calls with per-step verification). Returns a planId. Accepts explicit steps or asks the LLM planner. Planning is side-effect free.'),
    parameters: {
      type: 'object',
      properties: {
        goal: { type: 'string', description: 'What to accomplish, e.g. "Open the Tafiti project and start the dev server"' },
        steps: {
          type: 'array',
          description: 'Optional explicit steps (skips LLM planning). Each { tool, args, verify?: { tool, args, expect? } }.',
          items: {
            type: 'object',
            properties: {
              tool: { type: 'string' },
              args: { type: 'object' },
              verify: { type: 'object' }
            },
            required: ['tool']
          }
        }
      },
      required: ['goal']
    }
  },
  {
    name: 'execute_plan',
    description: sanitizeToolDescription('Execute a planned task step by step with verification, checkpoints, and one retry for transient failures. Resumes from the last checkpoint on re-run. Stops (never guesses) at the first failing step.'),
    parameters: {
      type: 'object',
      properties: {
        planId: { type: 'string', description: 'Plan ID from plan_task (plan-<id>)' }
      },
      required: ['planId']
    }
  },
  {
    name: 'plan_status',
    description: sanitizeToolDescription('Show a plan with per-step results and the resume checkpoint.'),
    parameters: {
      type: 'object',
      properties: {
        planId: { type: 'string', description: 'Plan ID (plan-<id>)' }
      },
      required: ['planId']
    }
  },
  {
    name: 'list_plans',
    description: sanitizeToolDescription('List recent task plans with status and progress.'),
    parameters: {
      type: 'object',
      properties: {
        limit: { type: 'number', description: 'Max plans (default 20)', default: 20 }
      },
      required: []
    }
  },
  {
    name: 'cancel_plan',
    description: sanitizeToolDescription('Cancel a running or planned task. The executor stops at the next step boundary.'),
    parameters: {
      type: 'object',
      properties: {
        planId: { type: 'string', description: 'Plan ID (plan-<id>)' }
      },
      required: ['planId']
    }
  },
  {
    name: 'spawn_agent',
    description: sanitizeToolDescription('Spawn a specialist sub-agent with a role, instructions, and a deny-by-default tool allowlist. High-risk toolsets run in an isolated process; safe ones run in-process. The agent reports a structured result; watch it via agent_status or /tasks.'),
    parameters: {
      type: 'object',
      properties: {
        role: { type: 'string', description: 'Short role label, e.g. "researcher", "coder", "tester"' },
        instructions: { type: 'string', description: 'The objective and constraints for the sub-agent' },
        allowed_tools: {
          type: 'array',
          description: 'Deny-by-default tool allowlist — ONLY these tools may be called',
          items: { type: 'string' }
        },
        isolation: { type: 'string', description: '"auto" (default: spawned for high-risk tools), "shared", or "spawned"', default: 'auto' },
        max_steps: { type: 'number', description: 'Step budget, 1–50 (default 15)', default: 15 },
        timeoutMs: { type: 'number', description: 'Timeout in ms, 1000–1800000 (default 600000)', default: 600000 },
        waitMs: { type: 'number', description: 'How long to wait for completion before returning (0 = return immediately once spawned/started)', default: 0 }
      },
      required: ['role', 'allowed_tools']
    }
  },
  {
    name: 'list_agents',
    description: sanitizeToolDescription('List sub-agents with status, depth, and parent linkage.'),
    parameters: {
      type: 'object',
      properties: {
        limit: { type: 'number', description: 'Max agents (default 20)', default: 20 },
        active_only: { type: 'boolean', description: 'Only spawned/running/waiting agents', default: false }
      },
      required: []
    }
  },
  {
    name: 'agent_status',
    description: sanitizeToolDescription('Full detail for one sub-agent: status, role, instructions, budget, messages, result.'),
    parameters: {
      type: 'object',
      properties: {
        agentId: { type: 'string', description: 'Agent ID (agent-<id>)' }
      },
      required: ['agentId']
    }
  },
  {
    name: 'cancel_agent',
    description: sanitizeToolDescription('Cancel a sub-agent. In-process loops stop at the next step; spawned workers observe cancellation via the store.'),
    parameters: {
      type: 'object',
      properties: {
        agentId: { type: 'string', description: 'Agent ID (agent-<id>)' }
      },
      required: ['agentId']
    }
  },
  {
    name: 'send_to_agent',
    description: sanitizeToolDescription('Queue a text message for a live sub-agent (e.g. new findings, course corrections). Refused once the agent is finished.'),
    parameters: {
      type: 'object',
      properties: {
        agentId: { type: 'string', description: 'Agent ID (agent-<id>)' },
        text: { type: 'string', description: 'Message text (max 2000 chars)' },
        from: { type: 'string', description: 'Sender label (default "supervisor")' }
      },
      required: ['agentId', 'text']
    }
  },
  {
    name: 'undo_last',
    description: sanitizeToolDescription('Reverse the most recent undoable action the agent took (file moves/renames, created files, memory/workflow changes). Shell commands and computer-use actions are journaled but only reversible by a human.'),
    parameters: { type: 'object', properties: {}, required: [] }
  },
  {
    name: 'undo_session',
    description: sanitizeToolDescription('Reverse every automatically-reversible action from a voice-agent session, newest first. Non-reversible actions are skipped and listed.'),
    parameters: {
      type: 'object',
      properties: {
        sessionId: { type: 'string', description: 'Session ID (defaults to the current agent session)' },
        limit: { type: 'number', description: 'Max actions to reverse (default 50, cap 200)', default: 50 }
      },
      required: []
    }
  },
  {
    name: 'list_undo',
    description: sanitizeToolDescription('List journaled actions with their undo status and reversibility (read-only).'),
    parameters: {
      type: 'object',
      properties: {
        limit: { type: 'number', description: 'Max records (default 20, cap 100)', default: 20 },
        pendingOnly: { type: 'boolean', description: 'Only not-yet-undone actions (default true)', default: true },
        sessionId: { type: 'string', description: 'Filter by session ID' }
      },
      required: []
    }
  }
];

// Tool handler mapping
const SCREEN_VERIFY_TOOLS = ['move_mouse', 'click_mouse', 'type_text', 'press_keys'];
// Mutating tools journaled for undo. Manual-reversibility tools (run_command,
// terminal_*, computer_use, kill_process) get before-state records only.
const UNDO_JOURNAL_TOOLS = new Set([
  'file_organize', 'file_rename', 'file_convert',
  'remember', 'forget', 'save_workflow', 'delete_workflow',
  'run_command', 'terminal_execute', 'computer_use', 'kill_process',
]);
const allHandlers = {
  web_search: webSearch,
  search_emails: async () => ({
    error: 'Google OAuth is disabled. Use computer_use to check or manage emails in the browser.'
  }),
  send_email: async () => ({
    error: 'Google OAuth is disabled. Use computer_use to compose and send emails in the browser.'
  }),
  list_events: async () => ({
    error: 'Google OAuth is disabled. Use computer_use to view your calendar in the browser.'
  }),
  create_event: async () => ({
    error: 'Google OAuth is disabled. Use computer_use to add events to your calendar in the browser.'
  }),
  move_mouse: moveMouse,
  click_mouse: clickMouse,
  type_text: typeText,
  press_keys: pressKeys,
  system_status: systemStatus,
  list_processes: listProcesses,
  kill_process: killProcess,
  run_command: runCommand,
  open_application: openApplication,
  list_installed_apps: listInstalledApps,
  manage_windows: manageWindows,
  media_control: mediaControl,
  clipboard: clipboardControl,
  file_organize: organizeFolder,
  file_rename: renameFiles,
  file_find: findFiles,
  file_convert: convertDocument,
  computer_use: runComputerUseTask,
  remember: rememberMemory,
  recall: recallMemory,
  forget: forgetMemory,
  resolve_location: resolvePlace,
  save_workflow: saveWorkflow,
  list_workflows: async (args) => listWorkflows(args),
  delete_workflow: deleteWorkflow,
  // Injected dispatcher avoids a tools.js <-> memory.js import cycle.
  run_workflow: async (args) => {
    setNestedUndoContext({ workflow: args?.name });
    try {
      return await runWorkflow(args, dispatchTool);
    } finally {
      setNestedUndoContext(null);
    }
  },
  terminal_execute: terminalExecute,
  terminal_start: terminalStart,
  terminal_read: terminalRead,
  terminal_input: terminalInput,
  terminal_kill: terminalKill,
  plan_task: planTask,
  plan_status: planStatus,
  list_plans: async (args) => listPlans(args),
  cancel_plan: cancelPlan,
  // Injected dispatcher avoids a tools.js <-> plan.js import cycle.
  execute_plan: async (args) => {
    setNestedUndoContext({ planId: args?.planId });
    try {
      return await executePlan(args, dispatchTool);
    } finally {
      setNestedUndoContext(null);
    }
  },

  undo_last: undoLast,
  undo_session: undoSession,
  list_undo: listUndo,
  // Injected dispatcher avoids a tools.js <-> agents.js import cycle.
  // Sub-agent depth: voice-dispatch roots at -1 so first spawn is depth 0.
  spawn_agent: (args) => spawnAgent(args, dispatchTool, { parentDepth: -1 }),
  list_agents: listAgents,
  agent_status: agentStatus,
  cancel_agent: cancelAgent,
  send_to_agent: sendToAgent
};

// Main dispatcher function with security checks
/**
 * Dispatch tool calls with comprehensive security checks and error handling
 * Handles unknown tools, rate limiting, argument validation, confirmation gates,
 * screen verification, and audit logging. All errors are caught and returned safely.
 * Includes performance monitoring and structured logging.
 * 
 * @param {string} name - Tool name to execute
 * @param {Object} args - Tool arguments
 * @returns {Promise<Object>} Tool result or error object
 */
export async function dispatchTool(name, args) {
  // No args in metadata: metrics are served over /api/metrics and must not
  // duplicate sensitive tool arguments (the audit log is the proper record).
  const timerId = perfMonitor.startTiming(name);
  const entry = {
    timestamp: new Date().toISOString(),
    tool: name,
    arguments: args
  };

  // Validate tool name
  if (!name || typeof name !== 'string') {
    const error = 'Invalid tool name: must be a non-empty string';
    entry.error = error;
    await writeAuditLog(entry);
    await logSecurityEvent('INVALID_TOOL_NAME', { tool: name });
    perfMonitor.stopTiming(timerId, false, new Error(error));
    logger.error('Invalid tool name', { tool: name });
    return { error };
  }

  const handler = allHandlers[name];
  if (!handler) {
    const error = `Unknown tool: ${name}. Available tools: ${Object.keys(allHandlers).join(', ')}`;
    entry.error = error;
    await writeAuditLog(entry);
    await logSecurityEvent('UNKNOWN_TOOL_ACCESS', { tool: name, args });
    perfMonitor.stopTiming(timerId, false, new Error(error));
    logger.error('Unknown tool accessed', { tool: name, availableTools: Object.keys(allHandlers) });
    return { error };
  }

  logger.debug('Tool dispatch started', { tool: name, args });

  // Security checks
  try {
    // Rate limiting for dangerous tools (computer_use has its own per-action
    // confirmation gates inside the task, so it is rate-limited but not
    // double-gated by the coarse approval queue).
    if ((requiresConfirmation(name) || name === 'computer_use') && !checkRateLimit(name)) {
      const error = `Rate limit exceeded for tool: ${name}. Please wait before retrying.`;
      entry.error = error;
      await writeAuditLog(entry);
      await logSecurityEvent('RATE_LIMIT_EXCEEDED', { tool: name });
      perfMonitor.stopTiming(timerId, false, new Error(error));
      logger.warn('Rate limit exceeded', { tool: name });
      return { error };
    }

    // Argument validation
    const validationErrors = validateToolArguments(name, args);
    if (validationErrors.length > 0) {
      const error = `Argument validation failed: ${validationErrors.join(', ')}`;
      entry.error = error;
      Promise.allSettled([
        writeAuditLog(entry),
        logSecurityEvent('ARGUMENT_VALIDATION_FAILED', { tool: name, errors: validationErrors })
      ]);
      perfMonitor.stopTiming(timerId, false, new Error(error));
      logger.warn('Argument validation failed', { tool: name, errors: validationErrors });
      return { error };
    }

    // Confirmation gate for dangerous tools — human-in-the-loop via /api/confirm UI.
    // Set AUTO_APPROVE=true for dev; otherwise the dispatcher waits for approval.
    if (requiresConfirmation(name)) {
      await logSecurityEvent('DANGEROUS_TOOL_EXECUTION', { tool: name, args });

      // 1) Screenshot verification for device-control tools (opt-in via SCREEN_VERIFY=true)
      if (SCREEN_VERIFY_TOOLS.includes(name)) {
        const screen = await verifyScreenBeforeControl(name, args);
        entry.screenVerification = screen;
        if (!screen.ok) {
          const error = `Screen verification failed: ${screen.reason}`;
          entry.error = error;
          Promise.allSettled([
            writeAuditLog(entry),
            logSecurityEvent('SCREEN_VERIFY_FAILED', { tool: name, reason: screen.reason })
          ]);
          perfMonitor.stopTiming(timerId, false, new Error(error));
          logger.warn('Screen verification failed', { tool: name, reason: screen.reason });
          return { error };
        }
        if (screen.screenshot) entry.screenshot = screen.screenshot;
      }

      // 2) Human approval (auto-approves iff AUTO_APPROVE=true)
      const isAuto = cfg('AUTO_APPROVE', 'false').toLowerCase() === 'true';
      if (!isAuto) {
        console.log(`⚠️  Dangerous tool requested: ${name} ${JSON.stringify(args)}`);
        console.log(`   Approve at http://localhost:${cfg('PORT', '3000')}/api/confirm (or set AUTO_APPROVE=true for dev)`);
        playEarcon('attention');
      }
      const decision = await requestApproval(name, args);
      if (decision.auto || isAuto) {
        console.log(`⚡ Auto-approved dangerous tool: ${name}`);
      }
      entry.approval = decision;
      if (!decision.approved) {
        const error = `Execution denied: ${decision.reason || 'not approved'}`;
        entry.error = error;
        Promise.allSettled([
          writeAuditLog(entry),
          logSecurityEvent('CONFIRMATION_DENIED', { tool: name })
        ]);
        perfMonitor.stopTiming(timerId, false, new Error(error));
        logger.warn('Tool execution denied', { tool: name, reason: decision.reason });
        return { error };
      }
    }

    // Undo journaling: capture pre-state, execute, journal the reversal.
    // Journaling must never break tool execution or change the result.
    let before = null;
    const journalable = UNDO_JOURNAL_TOOLS.has(name);
    if (journalable) {
      try { before = await captureBefore(name, args); } catch { before = null; }
    }
    const result = await handler(args);
    if (journalable) {
      try {
        const cap = await captureAfter(name, args, result, before);
        if (cap) {
          await undoRecord({
            tool: name,
            args,
            sessionId: process.env.AGENT_SESSION_ID || nestedUndoContext?.sessionId || null,
            planId: nestedUndoContext?.planId || null,
            agentId: nestedUndoContext?.agentId || null,
            ...cap,
          });
        }
      } catch (err) {
        logger.warn('undo journal capture failed', { tool: name, error: err.message });
      }
    }
    entry.result = result;
    writeAuditLog(entry).catch(() => {});
    const perf = perfMonitor.stopTiming(timerId, true);
    logger.info('Tool executed successfully', { tool: name, duration: perf?.duration });
    return result;
  } catch (err) {
    // Enhanced error handling with stack traces for debugging
    const errorMessage = err.message || 'Unknown error occurred';
    const errorDetails = {
      message: errorMessage,
      tool: name,
      timestamp: new Date().toISOString(),
      stack: process.env.NODE_ENV === 'development' ? err.stack : undefined
    };
    
    entry.error = errorMessage;
    entry.errorDetails = errorDetails;
    Promise.allSettled([
      writeAuditLog(entry),
      logSecurityEvent('TOOL_EXECUTION_ERROR', { tool: name, error: errorMessage, details: errorDetails })
    ]);
    perfMonitor.stopTiming(timerId, false, err);
    logger.error('Tool execution error', { tool: name, error: errorMessage, stack: errorDetails.stack });
    
    return { 
      error: errorMessage,
      tool: name,
      timestamp: errorDetails.timestamp
    };
  }
}

// Write to audit log (DuckDB tool_audit table; best-effort, never throws)
async function writeAuditLog(entry) {
  await appendToolAudit(entry);
}

// ---------- undo tools (vision item #2) ----------

// The most recent pending undoable action, newest first. Manual-reversibility
// records (commands, computer use) are surfaced but never auto-applied.
async function undoLast() {
  const rows = await undoList({ limit: 50, pendingOnly: true });
  if (!rows.length) return { success: false, message: 'Nothing to undo — no journaled actions found.' };
  const row = rows[0];
  if (!row.undo) {
    return {
      success: false,
      message: `The latest action (#${row.id}, ${row.tool}) has no automatic reversal — it is ${row.reversibility}-reversible. See list_undo for what changed; you decide how to revert it.`,
      record: { id: row.id, tool: row.tool, args: safeJsonParse(row.args), ts: row.ts },
    };
  }
  try {
    const applied = await applyRecord(row, 'undo');
    await undoMarkDone(row.id, null);
    return { success: true, message: `Undone: ${row.tool} — ${applied.join('; ')}`, undone: [{ id: row.id, tool: row.tool, applied }] };
  } catch (err) {
    return { success: false, message: `Undo of #${row.id} (${row.tool}) failed: ${err.message}`, record: { id: row.id, tool: row.tool } };
  }
}

// Reverse every automatically-reversible action from a session, newest first.
// Manual-only records are skipped and listed for the human.
async function undoSession(args = {}) {
  const sessionId = args?.sessionId || process.env.AGENT_SESSION_ID || null;
  if (!sessionId) {
  return { success: false, message: 'No session context available — pass sessionId or run from an active voice session.' };
}
  const limit = Math.min(Math.max(Number(args?.limit) || 50, 1), 200);
  const rows = await undoList({ limit: 500, sessionId, pendingOnly: true });
  if (!rows.length) return { success: false, message: 'Nothing to undo for this session.' };
  const undone = [];
  const skipped = [];
  const failed = [];
  for (const row of rows) {
    if (undone.length >= limit) { skipped.push({ id: row.id, tool: row.tool, reason: 'limit reached' }); continue; }
    if (!row.undo) { skipped.push({ id: row.id, tool: row.tool, reason: row.reversibility === 'manual' ? 'manual reversibility — human decides' : 'no reversal stored' }); continue; }
    try {
      const applied = await applyRecord(row, 'undo');
      await undoMarkDone(row.id, null);
      undone.push({ id: row.id, tool: row.tool, applied });
    } catch (err) {
      failed.push({ id: row.id, tool: row.tool, error: err.message });
    }
  }
  return { success: failed.length === 0, undoneCount: undone.length, skippedCount: skipped.length, undone, skipped, failed };
}

async function listUndo(args = {}) {
  const rows = await undoList({
    limit: Math.min(Math.max(Number(args?.limit) || 20, 1), 100),
    sessionId: args?.sessionId || undefined,
    pendingOnly: args?.pendingOnly !== false,
  });
  return {
    count: rows.length,
    actions: rows.map((r) => ({
      id: r.id,
      ts: r.ts,
      tool: r.tool,
      reversibility: r.reversibility,
      undone: !!r.undone_at,
      args: safeJsonParse(r.args),
    })),
  };
}

function safeJsonParse(s) {
  try { return s ? JSON.parse(s) : null; } catch { return s; }
}

// Helper function to build tools for AssemblyAI agent configuration
export function buildAllTools() {
  return toolDefinitions;
}