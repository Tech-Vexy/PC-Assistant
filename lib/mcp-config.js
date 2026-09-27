// Which MCP server backs which tool. Commands are overridable via config, so
// users can point at their own installed MCP servers. All entries fall back
// to the direct Google SDK handlers in tools/* on any failure.
//
// Built lazily (getMCPServers()) so DuckDB-backed values apply — the module
// is imported before the store boots. Precedence: process.env > DB > default.
import { cfg } from './store.js';

function parseArgs(raw, fallback) {
  if (raw === undefined || raw === '') return fallback;
  try {
    const parsed = JSON.parse(raw);
    return Array.isArray(parsed) ? parsed : fallback;
  } catch {
    return fallback;
  }
}

export function getMCPServers() {
  return {
    gmail: {
      command: cfg('MCP_GMAIL_CMD', 'npx'),
      args: parseArgs(cfg('MCP_GMAIL_ARGS'), ['-y', 'gmail-mcp-lib']),
      tools: { search: 'gmail_search', send: 'gmail_send' },
    },
    calendar: {
      command: cfg('MCP_CALENDAR_CMD', 'npx'),
      args: parseArgs(cfg('MCP_CALENDAR_ARGS'), ['-y', 'mcp-google-calendar']),
      tools: { list: 'calendar_list_events', create: 'calendar_create_event' },
    },
    search: {
      command: cfg('MCP_SEARCH_CMD', 'npx'),
      args: parseArgs(cfg('MCP_SEARCH_ARGS'), ['-y', 'mcp-google-custom-search']),
      tools: { web: 'web_search' },
    },
  };
}

// Backwards-compat static snapshot (env-only, pre-store-boot). Prefer getMCPServers().
export const MCP_SERVERS = getMCPServers();
