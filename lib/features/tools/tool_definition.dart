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
        'name': 'save_memory',
        'description':
            'Saves a durable fact about the user into long-term memory with semantic indexing. '
                'Automatically deduplicates and supersedes stale memories. '
                'Use this for facts that should persist across sessions (name, preferences, projects, goals).',
        'parameters': {
          'type': 'object',
          'properties': {
            'content': {
              'type': 'string',
              'description':
                  'Third-person statement about the user (e.g. "User prefers dark mode", '
                      '"User is building a Flutter assistant app")',
            },
            'category': {
              'type': 'string',
              'description':
                  'Category: identity, preference, project, location, goal, or general',
            },
            'importance': {
              'type': 'number',
              'description': 'Importance score 0.0–1.0 (default 0.5)',
            },
          },
          'required': ['content'],
        },
      },
      {
        'name': 'search_memories',
        'description':
            'Searches long-term memory using hybrid semantic + keyword search. '
                'Returns the most relevant memories for the query. '
                'Use this instead of recall when you need to find memories by meaning, not exact key.',
        'parameters': {
          'type': 'object',
          'properties': {
            'query': {
              'type': 'string',
              'description': 'Natural language query to search memories for',
            },
          },
          'required': ['query'],
        },
      },
      {
        'name': 'forget_topic',
        'description':
            'Erases all memories related to a topic from long-term memory. '
                'Use when the user says "forget about X" or "delete X from your memory".',
        'parameters': {
          'type': 'object',
          'properties': {
            'topic': {
              'type': 'string',
              'description':
                  'Topic or subject to erase (e.g. "my gym routine", "the Kyoto trip")',
            },
          },
          'required': ['topic'],
        },
      },
      {
        'name': 'memory_summary',
        'description':
            'Returns a summary of all long-term memories — what the assistant knows about this user. '
                'Use when the user asks "what do you know about me?" or "what do you remember?".',
        'parameters': {
          'type': 'object',
          'properties': {},
        },
      },
      {
        'name': 'generate_skill',
        'description':
            'Generates a new reusable workflow skill from a natural language description of a task. '
                'The skill is saved as a workflow that can be run or scheduled. '
                'Use when the user describes a repeatable task they want automated.',
        'parameters': {
          'type': 'object',
          'properties': {
            'description': {
              'type': 'string',
              'description':
                  'Natural language description of the task (e.g. "Every morning check the weather and open my calendar")',
            },
            'platform': {
              'type': 'string',
              'description': 'Target platform: "android" or "desktop"',
            },
          },
          'required': ['description'],
        },
      },
      {
        'name': 'learn_skill',
        'description':
            'Synthesizes a reusable workflow skill by observing a sequence of tool calls from recent history. '
                'Use to turn a just-completed sequence of actions into a named, reusable automation.',
        'parameters': {
          'type': 'object',
          'properties': {
            'name': {
              'type': 'string',
              'description': 'Name for the skill to learn (snake_case)',
            },
          },
          'required': ['name'],
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
        'name': 'save_workflow_skill',
        'description':
            'Saves a Hermes-format procedural workflow skill (YAML frontmatter + markdown execution guide + parameters). '
                'Features automatic static security scanning and append-only version ledger tracking for rollback.',
        'parameters': {
          'type': 'object',
          'properties': {
            'name': {
              'type': 'string',
              'description':
                  'Snake-case unique skill name (e.g. morning_briefing, pr_review_flow)',
            },
            'description': {
              'type': 'string',
              'description':
                  'One-line summary shown in progressive disclosure lists',
            },
            'markdown_content': {
              'type': 'string',
              'description':
                  'Complete markdown execution instructions, rules, and constraints',
            },
            'version': {
              'type': 'string',
              'description': 'Semantic version (default 1.0.0)',
            },
            'parameters': {
              'type': 'object',
              'description':
                  'Template parameter declarations with descriptions and defaults',
            },
            'steps': {
              'type': 'array',
              'description': 'Structured executable tool steps for automation',
              'items': {'type': 'object'},
            },
            'tags': {
              'type': 'array',
              'items': {'type': 'string'},
              'description':
                  'Tags for organization (e.g. ["routine", "productivity"])',
            },
            'change_summary': {
              'type': 'string',
              'description': 'Audit note explaining this version',
            },
          },
          'required': ['name', 'description', 'markdown_content'],
        },
      },
      {
        'name': 'patch_workflow_skill',
        'description':
            'Applies a surgical patch (search-and-replace) to an existing workflow skill without full rewrite. '
                'Increments the patch version and logs the change to the audit ledger.',
        'parameters': {
          'type': 'object',
          'properties': {
            'name': {
              'type': 'string',
              'description': 'Name of the workflow skill to patch',
            },
            'search_target': {
              'type': 'string',
              'description': 'Exact block of text in the workflow to replace',
            },
            'replacement': {
              'type': 'string',
              'description': 'Replacement content to substitute',
            },
            'change_summary': {
              'type': 'string',
              'description': 'Audit note describing what was changed',
            },
          },
          'required': ['name', 'search_target', 'replacement'],
        },
      },
      {
        'name': 'view_workflow_skill',
        'description':
            'Progressive Disclosure Level 2: Fetches full markdown instructions, rules, and parameter definitions for a specific workflow skill.',
        'parameters': {
          'type': 'object',
          'properties': {
            'name': {
              'type': 'string',
              'description': 'Name of the workflow skill to view',
            },
          },
          'required': ['name'],
        },
      },
      {
        'name': 'list_workflow_skills',
        'description':
            'Progressive Disclosure Level 1: Lists lightweight summaries of all saved workflow skills (name, description, version, tags) to minimize token consumption.',
        'parameters': {
          'type': 'object',
          'properties': {},
        },
      },
      {
        'name': 'rollback_workflow_skill',
        'description':
            'Rolls back a workflow skill to a previous historical version from the version ledger.',
        'parameters': {
          'type': 'object',
          'properties': {
            'name': {
              'type': 'string',
              'description': 'Name of the workflow skill to roll back',
            },
            'version_id': {
              'type': 'integer',
              'description': 'Target ledger version ID',
            },
          },
          'required': ['name', 'version_id'],
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
          'name': 'call_contact',
          'description':
              'Makes a phone call by operating the device default phone/dialer app directly via UI automation: opens dialer, searches/fills contact or phone number, clicks Call, and chooses the requested SIM card if prompted.',
          'parameters': {
            'type': 'object',
            'properties': {
              'contact_name': {
                'type': 'string',
                'description':
                    'Name of the contact to call (e.g. "Dad", "Alice", "Doctor")',
              },
              'phone_number': {
                'type': 'string',
                'description':
                    'Phone number to call if known (e.g. "+1234567890", "0712345678")',
              },
              'sim_slot': {
                'type': 'number',
                'description':
                    'SIM card slot to use on dual-SIM phones (1 or 2, default: 1)',
              },
              'sim_name': {
                'type': 'string',
                'description':
                    'Optional name or carrier of the SIM card (e.g. "SIM 1", "SIM 2", "Safaricom", "Airtel")',
              },
            },
          },
        },
        {
          'name': 'operate_dialer',
          'description':
              'Operates the phone/dialer application on the device. Takes a screenshot and hierarchy to determine layout, defines actions to make a call or search a contact, and saves the actions as a workflow referenced on subsequent calls.',
          'parameters': {
            'type': 'object',
            'properties': {
              'contact_name': {
                'type': 'string',
                'description': 'Name of the contact to call',
              },
              'phone_number': {
                'type': 'string',
                'description': 'Phone number to dial',
              },
              'sim_slot': {
                'type': 'number',
                'description': 'SIM card slot (1 or 2, default 1)',
              },
              'sim_name': {
                'type': 'string',
                'description': 'Optional SIM carrier name',
              },
              'goal': {
                'type': 'string',
                'description': 'Optional explicit goal (e.g. "call contact", "dial number")',
              },
            },
          },
        },
        {
          'name': 'operate_device',
          'description':
              'Operates any device application (including Phone/Dialer, WhatsApp, Clock, Settings) by taking a screenshot to determine layout, defining actions to take to operate the app, and saving the actions as a workflow referenced on subsequent operations of the same app.',
          'parameters': {
            'type': 'object',
            'properties': {
              'app_name': {
                'type': 'string',
                'description':
                    'Name of the target app (e.g. "Phone", "WhatsApp", "Clock", "Settings", "Spotify")',
              },
              'goal': {
                'type': 'string',
                'description':
                    'The specific user goal to achieve (e.g. "call Dad using SIM 1", "set alarm for 7 AM", "send message to Alice")',
              },
              'parameters': {
                'type': 'object',
                'description':
                    'Optional key-value parameters needed for the action (e.g. {"contact_name": "Dad", "sim_slot": 1})',
              },
            },
            'required': ['app_name', 'goal'],
          },
        },
        {
          'name': 'get_contacts',
          'description':
              'Searches and retrieves device contacts (names and phone numbers) to send SMS or make calls.',
          'parameters': {
            'type': 'object',
            'properties': {
              'query': {
                'type': 'string',
                'description': 'Name or number to filter by (optional)',
              },
            },
          },
        },
        {
          'name': 'lock_device',
          'description':
              'Immediately locks the device screen using Device Administrator privileges.',
          'parameters': {
            'type': 'object',
            'properties': {},
          },
        },
        {
          'name': 'request_device_admin',
          'description':
              'Prompts the user to grant Device Administrator elevation to Device Assistant.',
          'parameters': {
            'type': 'object',
            'properties': {},
          },
        },
        {
          'name': 'set_default_assistant',
          'description':
              'Opens Android system settings to set this app as the default device digital assistant.',
          'parameters': {
            'type': 'object',
            'properties': {},
          },
        },
        {
          'name': 'list_notifications',
          'description':
              'Retrieves active and recent device notifications from apps (WhatsApp, Telegram, Slack, Gmail, Messages, Calendar, etc.).',
          'parameters': {
            'type': 'object',
            'properties': {
              'unread_only': {
                'type': 'boolean',
                'description':
                    'If true, returns only unread/active notifications (default false)',
              },
              'app': {
                'type': 'string',
                'description':
                    'Filter by application name or package (e.g. "whatsapp", "slack", "gmail")',
              },
              'limit': {
                'type': 'number',
                'description': 'Maximum notifications to return (default 10)',
              },
            },
          },
        },
        {
          'name': 'triage_notifications',
          'description':
              'Performs an intelligent triage of incoming device notifications, grouping them into Urgent Messages, Informational Updates, and Low-Priority alerts with an executive narrative summary.',
          'parameters': {
            'type': 'object',
            'properties': {
              'limit': {
                'type': 'number',
                'description': 'Max notifications to evaluate (default 25)',
              },
            },
          },
        },
        {
          'name': 'reply_to_notification',
          'description':
              'Directly sends an inline message reply to an active notification (e.g. WhatsApp, Slack, Telegram, Signal, SMS) without opening the app.',
          'parameters': {
            'type': 'object',
            'properties': {
              'notification_key': {
                'type': 'string',
                'description':
                    'The unique key of the target notification (from list_notifications or triage_notifications)',
              },
              'reply_text': {
                'type': 'string',
                'description': 'The text reply to send',
              },
            },
            'required': ['notification_key', 'reply_text'],
          },
        },
        {
          'name': 'send_sms',
          'description':
              'Sends an SMS text message directly to a phone number or recipient.',
          'parameters': {
            'type': 'object',
            'properties': {
              'phone_number': {
                'type': 'string',
                'description': 'Recipient phone number',
              },
              'message': {
                'type': 'string',
                'description': 'Text message body to send',
              },
            },
            'required': ['phone_number', 'message'],
          },
        },
        {
          'name': 'read_notifications_summary',
          'description':
              'Generates a conversational executive audio briefing of unread and missed messages.',
          'parameters': {
            'type': 'object',
            'properties': {},
          },
        },
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
