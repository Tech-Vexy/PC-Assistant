// Tiny TTL LRU cache — no dependencies. Used for Gmail/Calendar/Search results.
export class TTLCache {
  constructor({ maxEntries = 200, defaultTtlMs = 60_000 } = {}) {
    this.maxEntries = maxEntries;
    this.defaultTtlMs = defaultTtlMs;
    this.map = new Map(); // key -> { value, expiresAt }
    this.hits = 0;
    this.misses = 0;
  }

  _isExpired(entry) {
    return Date.now() > entry.expiresAt;
  }

  get(key) {
    const entry = this.map.get(key);
    if (!entry) {
      this.misses++;
      return undefined;
    }
    if (this._isExpired(entry)) {
      this.map.delete(key);
      this.misses++;
      return undefined;
    }
    // LRU refresh
    this.map.delete(key);
    this.map.set(key, entry);
    this.hits++;
    return entry.value;
  }

  set(key, value, ttlMs = this.defaultTtlMs) {
    if (this.map.has(key)) this.map.delete(key);
    // Evict oldest if over capacity
    while (this.map.size >= this.maxEntries) {
      const oldestKey = this.map.keys().next().value;
      this.map.delete(oldestKey);
    }
    this.map.set(key, { value, expiresAt: Date.now() + ttlMs });
  }

  delete(key) {
    this.map.delete(key);
  }

  clear() {
    this.map.clear();
  }

  stats() {
    return { size: this.map.size, hits: this.hits, misses: this.misses };
  }
}

// Shared singleton caches with sensible TTLs
export const searchCache = new TTLCache({ maxEntries: 200, defaultTtlMs: 10 * 60_000 });
export const gmailCache = new TTLCache({ maxEntries: 200, defaultTtlMs: 2 * 60_000 });
export const calendarCache = new TTLCache({ maxEntries: 100, defaultTtlMs: 2 * 60_000 });
export const systemCache = new TTLCache({ maxEntries: 20, defaultTtlMs: 5_000 });

export function cacheKey(prefix, obj) {
  return `${prefix}:${JSON.stringify(obj ?? {})}`;
}
