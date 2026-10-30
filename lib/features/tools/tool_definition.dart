/// Unified tool definitions for Gemini Live function calling
class ToolDefinitions {
  static List<Map<String, dynamic>> getAllDeclarations(
      {required bool isAndroid}) {
    return [
      {
        'name': 'system_status',
        'description':
            'Retrieves device system metrics (battery, memory, platform, active app)',
        'parameters': {
          'type': 'object',
          'properties': {},
        },
      },
      {
        'name': 'remember',
        'description':
            'Saves a persistent user preference, fact, or location to encrypted memory',
        'parameters': {
          'type': 'object',
          'properties': {
            'key': {
              'type': 'string',
              'description':
                  'Short identifier (e.g. coffee_preference, home_address)',
            },
            'value': {
              'type': 'string',
              'description': 'Detailed value or description to remember',
            },
            'category': {
              'type': 'string',
              'description':
                  'Category: preference, location, workflow, or general',
            },
          },
          'required': ['key', 'value'],
        },
      },
      {
        'name': 'recall',
        'description':
            'Recalls a saved fact or preference from encrypted memory by key',
        'parameters': {
          'type': 'object',
          'properties': {
            'key': {
              'type': 'string',
              'description': 'Identifier to look up',
            },
          },
          'required': ['key'],
        },
      },
      {
        'name': 'list_memories',
        'description':
            'Lists saved user preferences, locations, and facts from encrypted memory',
        'parameters': {
          'type': 'object',
          'properties': {
            'category': {
              'type': 'string',
              'description':
                  'Optional filter category: preference, location, workflow, general',
            },
          },
        },
      },
      {
        'name': 'forget',
        'description':
            'Removes a saved preference, fact, or location from encrypted memory by key',
        'parameters': {
          'type': 'object',
          'properties': {
            'key': {
              'type': 'string',
              'description': 'Identifier of the memory to forget',
            },
          },
          'required': ['key'],
        },
      },
      {
        'name': 'undo_last',
        'description':
            'Reverses the last automated modification made by the assistant',
        'parameters': {
          'type': 'object',
          'properties': {},
        },
      },
      {
        'name': 'plan_task',
        'description':
            'Decomposes a complex multi-step user task into an executable plan using Nemotron',
        'parameters': {
          'type': 'object',
          'properties': {
            'goal': {
              'type': 'string',
              'description': 'The high-level user goal to plan',
            },
          },
          'required': ['goal'],
        },
      },
      {
        'name': 'execute_plan',
        'description':
            'Executes an existing plan decomposed by plan_task or a plan ID',
        'parameters': {
          'type': 'object',
          'properties': {
            'plan_id': {
              'type': 'string',
              'description': 'ID of the plan to execute',
            },
          },
          'required': ['plan_id'],
        },
      },
      {
        'name': 'list_plans',
        'description':
            'Lists all current and recent task plans with their execution status',
        'parameters': {
          'type': 'object',
          'properties': {},
        },
      },
      {
        'name': 'save_workflow',
        'description':
            'Saves a recurring multi-step procedure/workflow by name',
        'parameters': {
          'type': 'object',
          'properties': {
            'name': {
              'type': 'string',
              'description': 'Unique workflow identifier',
            },
            'description': {
              'type': 'string',
              'description': 'What this workflow accomplishes',
            },
            'steps': {
              'type': 'array',
              'description':
                  'List of steps to execute, each with tool and args',
              'items': {
                'type': 'object',
                'properties': {
                  'tool': {
                    'type': 'string',
                    'description': 'Name of the tool to execute',
                  },
                  'args': {
                    'type': 'object',
                    'properties': {},
                    'description': 'Arguments for the tool',
                  },
                },
                'required': ['tool'],
              },
            },
          },
          'required': ['name', 'steps'],
        },
      },
      {
        'name': 'run_workflow',
        'description': 'Runs a saved automated workflow by name',
        'parameters': {
          'type': 'object',
          'properties': {
            'name': {
              'type': 'string',
              'description': 'Workflow name to execute',
            },
          },
          'required': ['name'],
        },
      },
      {
        'name': 'list_workflows',
        'description': 'Lists all saved procedural workflows',
        'parameters': {
          'type': 'object',
          'properties': {},
        },
      },
      {
        'name': 'delete_workflow',
        'description': 'Deletes a saved workflow by name',
        'parameters': {
          'type': 'object',
          'properties': {
            'name': {
              'type': 'string',
              'description': 'Workflow name to delete',
            },
          },
          'required': ['name'],
        },
      },
      {
        'name': 'schedule_workflow',
        'description':
            'Schedules a saved workflow to run periodically on a recurring interval',
        'parameters': {
          'type': 'object',
          'properties': {
            'workflow_name': {
              'type': 'string',
              'description': 'Name of the workflow to schedule',
            },
            'interval_seconds': {
              'type': 'number',
              'description':
                  'Execution interval in seconds (minimum 10 seconds)',
            },
          },
          'required': ['workflow_name', 'interval_seconds'],
        },
      },
      {
        'name': 'list_scheduled_workflows',
        'description':
            'Lists all scheduled and recurring workflows with their next execution times',
        'parameters': {
          'type': 'object',
          'properties': {},
        },
      },
      {
        'name': 'cancel_scheduled_workflow',
        'description':
            'Cancels a recurring scheduled workflow by its schedule ID',
        'parameters': {
          'type': 'object',
          'properties': {
            'schedule_id': {
              'type': 'string',
              'description': 'Unique identifier of the schedule to cancel',
            },
          },
          'required': ['schedule_id'],
        },
      },
      {
        'name': 'open_application',
        'description':
            'Launches an installed application. Use package_name (e.g. com.chrome.dev) when known for exact targeting — '
                'especially important when multiple variants exist (e.g. Chrome Stable vs Chrome Dev vs Chrome Beta). '
                'Use list_installed_apps first to find the exact package_name if you are unsure which variant the user wants.',
        'parameters': {
          'type': 'object',
          'properties': {
            'app_name': {
              'type': 'string',
              'description':
                  'Human-readable app name (e.g. "Google Chrome Dev", "Chrome Beta"). Used when package_name is unknown.',
            },
            'package_name': {
              'type': 'string',
              'description':
                  'Exact Android package name (e.g. com.chrome.dev). Preferred over app_name for precise targeting.',
            },
          },
        },
      },
      if (isAndroid) ...[
        {
          'name': 'list_installed_apps',
          'description':
              'Lists all installed launcher apps on the device with their human-readable name and exact package name. '
                  'Call this before open_application when you need to distinguish between similar app variants '
                  '(e.g. Chrome Stable vs Chrome Dev vs Chrome Beta, or multiple browser installs).',
          'parameters': {
            'type': 'object',
            'properties': {
              'filter': {
                'type': 'string',
                'description':
                    'Optional keyword to filter results (e.g. "chrome" returns only apps with "chrome" in name or package)',
              },
            },
          },
        },
      ],
      {
        'name': 'inspect_screen',
        'description':
            'Captures visual screen state or UI hierarchy to answer user queries',
        'parameters': {
          'type': 'object',
          'properties': {
            'query': {
              'type': 'string',
              'description':
                  'What information the user wants to identify from the screen',
            },
          },
        },
      },
      if (!isAndroid) ...[
        {
          'name': 'run_shell_command',
          'description':
              'Executes a desktop terminal command (PowerShell on Windows, Bash on Linux)',
          'parameters': {
            'type': 'object',
            'properties': {
              'command': {
                'type': 'string',
                'description': 'The command to execute',
              },
            },
            'required': ['command'],
          },
        },
      ] else ...[
        {
          'name': 'click_element',
          'description':
              'Clicks a visible UI element on mobile by its visible label',
          'parameters': {
            'type': 'object',
            'properties': {
              'text': {
                'type': 'string',
                'description':
                    'The exact visible text of the button or item to click',
              },
            },
            'required': ['text'],
          },
        },
        {
          'name': 'touch_gesture',
          'description': 'Performs a tap or swipe gesture on the mobile screen',
          'parameters': {
            'type': 'object',
            'properties': {
              'type': {
                'type': 'string',
                'description': 'Gesture type: "tap" or "swipe"',
              },
              'x': {'type': 'number', 'description': 'X coordinate for tap'},
              'y': {'type': 'number', 'description': 'Y coordinate for tap'},
              'startX': {
                'type': 'number',
                'description': 'Start X coordinate for swipe'
              },
              'startY': {
                'type': 'number',
                'description': 'Start Y coordinate for swipe'
              },
              'endX': {
                'type': 'number',
                'description': 'End X coordinate for swipe'
              },
              'endY': {
                'type': 'number',
                'description': 'End Y coordinate for swipe'
              },
            },
            'required': ['type'],
          },
        },
        {
          'name': 'navigate',
          'description':
              'Performs Android system navigation (back, home, recents, notifications)',
          'parameters': {
            'type': 'object',
            'properties': {
              'action': {
                'type': 'string',
                'description':
                    'Action: "back", "home", "recents", "notifications"',
              },
            },
            'required': ['action'],
          },
        },
        {
          'name': 'input_text',
          'description':
              'Types or inputs text into the currently focused or targeted editable field',
          'parameters': {
            'type': 'object',
            'properties': {
              'text': {
                'type': 'string',
                'description': 'The text string to type'
              },
              'view_id': {
                'type': 'string',
                'description': 'Optional resource ID of the target input'
              },
            },
            'required': ['text'],
          },
        },
        {
          'name': 'scroll_screen',
          'description':
              'Scrolls the active window forward (down) or backward (up)',
          'parameters': {
            'type': 'object',
            'properties': {
              'direction': {
                'type': 'string',
                'description': '"down" or "up" (default "down")'
              },
            },
          },
        },
        {
          'name': 'capture_screen',
          'description':
              'Captures a real-time visual frame of the screen for multimodal reasoning',
          'parameters': {
            'type': 'object',
            'properties': {},
          },
        },
      ],
      {
        'name': 'web_search',
        'description':
            'Searches the web or synthesizes real-time knowledge to answer factual and current questions',
        'parameters': {
          'type': 'object',
          'properties': {
            'query': {
              'type': 'string',
              'description': 'Search query or factual question to look up',
            },
          },
          'required': ['query'],
        },
      },
      {
        'name': 'pc_status',
        'description':
            'Checks the connection status and health of the linked PC Assistant desktop server',
        'parameters': {
          'type': 'object',
          'properties': {},
        },
      },
      {
        'name': 'sync_memories',
        'description':
            'Synchronizes memories between this device and the linked PC Assistant server',
        'parameters': {
          'type': 'object',
          'properties': {},
        },
      },
      {
        'name': 'sync_workflows',
        'description':
            'Synchronizes workflows between this device and the linked PC Assistant server',
        'parameters': {
          'type': 'object',
          'properties': {},
        },
      },
      {
        'name': 'computer_use',
        'description':
            'Executes direct computer use and GUI actions on desktop/mobile interface (clicks, keystrokes, gestures, coordinate actions, command execution) powered by Google Gemini',
        'parameters': {
          'type': 'object',
          'properties': {
            'action': {
              'type': 'string',
              'description':
                  'Action to execute: "click", "mouse_move", "type", "scroll", "screenshot", "shell"',
            },
            'coordinate': {
              'type': 'array',
              'items': {'type': 'number'},
              'description': '[x, y] coordinates for click or tap',
            },
            'text': {
              'type': 'string',
              'description': 'Text string to type into the focused element',
            },
            'command': {
              'type': 'string',
              'description': 'Terminal or shell command to execute',
            },
            'direction': {
              'type': 'string',
              'description': 'Scroll direction: "down" or "up"',
            },
          },
          'required': ['action'],
        },
      },
      {
        'name': 'delegate_to_pc',
        'description':
            'Delegates execution of a desktop tool to the linked PC Assistant server (e.g. computer_use, terminal, media)',
        'parameters': {
          'type': 'object',
          'properties': {
            'tool': {
              'type': 'string',
              'description': 'Tool name to execute on the PC server',
            },
            'args': {
              'type': 'object',
              'properties': {},
              'description': 'Arguments for the tool',
            },
          },
          'required': ['tool'],
        },
      },
      {
        'name': 'spawn_agent',
        'description':
            'Dynamically spawns a specialized sub-agent with a dedicated role, scoped allowed tools, and autonomous loop',
        'parameters': {
          'type': 'object',
          'properties': {
            'role': {
              'type': 'string',
              'description':
                  'Sub-agent role title (e.g. "Research Assistant", "Device Automator")',
            },
            'instructions': {
              'type': 'string',
              'description':
                  'Clear, actionable instructions and goals for the sub-agent to accomplish',
            },
            'allowed_tools': {
              'type': 'array',
              'items': {'type': 'string'},
              'description':
                  'Explicit allowlist of tool names permitted for this sub-agent (deny-by-default)',
            },
            'max_steps': {
              'type': 'integer',
              'description':
                  'Maximum reasoning/action steps before concluding (default 10)',
            },
            'timeout_ms': {
              'type': 'integer',
              'description': 'Timeout in milliseconds (default 60000)',
            },
          },
          'required': ['role', 'instructions', 'allowed_tools'],
        },
      },
      {
        'name': 'list_agents',
        'description':
            'Lists all active or recent sub-agents with their status and step progress',
        'parameters': {
          'type': 'object',
          'properties': {
            'status': {
              'type': 'string',
              'description':
                  'Optional filter: "running", "completed", "failed", "cancelled"',
            },
          },
        },
      },
      {
        'name': 'agent_status',
        'description':
            'Retrieves detailed execution status, history, and results for a specific sub-agent',
        'parameters': {
          'type': 'object',
          'properties': {
            'agent_id': {
              'type': 'string',
              'description': 'Unique sub-agent ID',
            },
          },
          'required': ['agent_id'],
        },
      },
      {
        'name': 'cancel_agent',
        'description': 'Cancels an active sub-agent by ID',
        'parameters': {
          'type': 'object',
          'properties': {
            'agent_id': {
              'type': 'string',
              'description': 'Unique sub-agent ID to terminate',
            },
          },
          'required': ['agent_id'],
        },
      },
      {
        'name': 'send_to_agent',
        'description':
            'Sends a follow-up message or instruction to an active sub-agent',
        'parameters': {
          'type': 'object',
          'properties': {
            'agent_id': {
              'type': 'string',
              'description': 'Target sub-agent ID',
            },
            'message': {
              'type': 'string',
              'description': 'Message or additional instruction content',
            },
          },
          'required': ['agent_id', 'message'],
        },
      },
    ];
  }
}
