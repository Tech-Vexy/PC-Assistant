// Google Search integration: MCP first, Google Custom Search if configured,
// and native Gemini Google Search Grounding fallback (zero-setup using GEMINI_API_KEY).
import { tryMCPTool, normalizeMCPResult } from '../lib/mcp-client.js';
import { getMCPServers } from '../lib/mcp-config.js';
import { searchCache, cacheKey } from '../lib/cache.js';
import { cfg } from '../lib/store.js';

export async function webSearch(args) {
  const { query, maxResults = 5 } = args;

  const key = cacheKey('web-search', { query, maxResults });
  const cached = searchCache.get(key);
  if (cached) return cached;

  // 1) True MCP path (stdio JSON-RPC)
  const mcpServers = getMCPServers();
  if (mcpServers?.search) {
    const mcp = await tryMCPTool(
      'search',
      mcpServers.search.command,
      mcpServers.search.args,
      mcpServers.search.tools?.web,
      { query, maxResults }
    );
    if (mcp.ok) {
      const normalized = normalizeMCPResult(mcp.result);
      searchCache.set(key, normalized);
      return normalized;
    }
  }

  // 2) Google Custom Search if API key + CX are explicitly configured
  const apiKey = cfg('GOOGLE_SEARCH_API_KEY');
  const cx = cfg('GOOGLE_SEARCH_CX');

  if (apiKey && cx) {
    try {
      const url = new URL('https://www.googleapis.com/customsearch/v1');
      url.searchParams.set('key', apiKey);
      url.searchParams.set('cx', cx);
      url.searchParams.set('q', query);
      url.searchParams.set('num', maxResults.toString());

      const response = await fetch(url.toString());
      if (response.ok) {
        const data = await response.json();
        if (data.items) {
          const results = data.items.map((item) => ({
            title: item.title,
            link: item.link,
            snippet: item.snippet,
            displayLink: item.displayLink,
          }));
          const result = { results, count: results.length };
          searchCache.set(key, result);
          return result;
        }
      }
    } catch {
      // Fall through to Gemini Grounding
    }
  }

  // 3) Native Gemini Grounded Search (uses existing GEMINI_API_KEY, no CX needed)
  const geminiKey = cfg('GEMINI_API_KEY');
  if (geminiKey) {
    try {
      const { GoogleGenAI } = await import('@google/genai');
      const ai = new GoogleGenAI({ apiKey: geminiKey });
      const model = cfg('GEMINI_MODEL', 'gemini-2.5-flash');
      const response = await ai.models.generateContent({
        model,
        contents: query,
        config: {
          tools: [{ googleSearch: {} }],
        },
      });

      const text = response?.text || '';
      const chunks = response?.candidates?.[0]?.groundingMetadata?.groundingChunks || [];
      const sources = chunks
        .filter((c) => c?.web?.uri)
        .map((c) => {
          let hostname = '';
          try {
            hostname = new URL(c.web.uri).hostname;
          } catch {
            hostname = c.web.uri;
          }
          return {
            title: c.web.title || hostname,
            link: c.web.uri,
            snippet: text.slice(0, 160),
            displayLink: hostname,
          };
        });

      const result = {
        summary: text,
        results: sources.slice(0, maxResults),
        count: sources.length,
      };
      searchCache.set(key, result);
      return result;
    } catch (error) {
      throw new Error(`Web search failed: ${error.message}`);
    }
  }

  throw new Error(
    'Web search credentials not configured. Please set GEMINI_API_KEY (for Google Search Grounding) or GOOGLE_SEARCH_API_KEY and GOOGLE_SEARCH_CX.'
  );
}
