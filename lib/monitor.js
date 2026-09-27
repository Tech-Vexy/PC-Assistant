/**
 * Monitoring and logging enhancements
 * 
 * This module provides enhanced monitoring capabilities including:
 * - Performance metrics collection
 * - Health check endpoints
 * - Structured logging with levels
 * - Error tracking and aggregation
 * - Resource usage monitoring
 */

import os from 'os';

// Log levels
const LOG_LEVELS = {
  DEBUG: 0,
  INFO: 1,
  WARN: 2,
  ERROR: 3,
  FATAL: 4
};

// Current log level (configurable via environment)
const CURRENT_LOG_LEVEL = LOG_LEVELS[process.env.LOG_LEVEL?.toUpperCase()] || LOG_LEVELS.INFO;

// Performance metrics storage
const metrics = {
  toolExecutions: new Map(),
  apiCalls: new Map(),
  errors: [],
  performanceSamples: []
};

// Maximum number of performance samples to keep
const MAX_PERFORMANCE_SAMPLES = 1000;
const MAX_ERROR_SAMPLES = 100;

/**
 * Enhanced logger with structured output
 */
class Logger {
  constructor(component) {
    this.component = component;
    this.startTime = Date.now();
    this.counters = {
      debug: 0,
      info: 0,
      warn: 0,
      error: 0,
      fatal: 0
    };
  }

  /**
   * Format log message with timestamp and component
   */
  formatMessage(level, message, meta = {}) {
    const timestamp = new Date().toISOString();
    const levelStr = Object.keys(LOG_LEVELS).find(key => LOG_LEVELS[key] === level);
    return {
      timestamp,
      level: levelStr,
      component: this.component,
      message,
      ...meta,
      uptime: Date.now() - this.startTime
    };
  }

  /**
   * Log at DEBUG level
   */
  debug(message, meta = {}) {
    if (CURRENT_LOG_LEVEL <= LOG_LEVELS.DEBUG) {
      const logEntry = this.formatMessage(LOG_LEVELS.DEBUG, message, meta);
      console.debug(JSON.stringify(logEntry));
      this.counters.debug++;
    }
  }

  /**
   * Log at INFO level
   */
  info(message, meta = {}) {
    if (CURRENT_LOG_LEVEL <= LOG_LEVELS.INFO) {
      const logEntry = this.formatMessage(LOG_LEVELS.INFO, message, meta);
      console.log(JSON.stringify(logEntry));
      this.counters.info++;
    }
  }

  /**
   * Log at WARN level
   */
  warn(message, meta = {}) {
    if (CURRENT_LOG_LEVEL <= LOG_LEVELS.WARN) {
      const logEntry = this.formatMessage(LOG_LEVELS.WARN, message, meta);
      console.warn(JSON.stringify(logEntry));
      this.counters.warn++;
    }
  }

  /**
   * Log at ERROR level
   */
  error(message, meta = {}) {
    if (CURRENT_LOG_LEVEL <= LOG_LEVELS.ERROR) {
      const logEntry = this.formatMessage(LOG_LEVELS.ERROR, message, meta);
      console.error(JSON.stringify(logEntry));
      this.counters.error++;
      
      // Track error for monitoring
      this.trackError(logEntry);
    }
  }

  /**
   * Log at FATAL level
   */
  fatal(message, meta = {}) {
    if (CURRENT_LOG_LEVEL <= LOG_LEVELS.FATAL) {
      const logEntry = this.formatMessage(LOG_LEVELS.FATAL, message, meta);
      console.error(JSON.stringify(logEntry));
      this.counters.fatal++;
      
      // Track error for monitoring
      this.trackError(logEntry);
    }
  }

  /**
   * Track error for monitoring
   */
  trackError(logEntry) {
    metrics.errors.push({
      ...logEntry,
      stack: logEntry.stack
    });
    
    // Keep only recent errors
    if (metrics.errors.length > MAX_ERROR_SAMPLES) {
      metrics.errors.shift();
    }
  }

  /**
   * Get log statistics
   */
  getStats() {
    return {
      component: this.component,
      uptime: Date.now() - this.startTime,
      counters: { ...this.counters }
    };
  }
}

/**
 * Performance monitoring for tool execution
 */
class PerformanceMonitor {
  constructor() {
    this.activeTimers = new Map();
  }

  /**
   * Start timing a tool execution
   */
  startTiming(toolName, metadata = {}) {
    const id = `${toolName}-${Date.now()}-${Math.random()}`;
    this.activeTimers.set(id, {
      toolName,
      startTime: Date.now(),
      metadata
    });
    return id;
  }

  /**
   * Stop timing and record performance
   */
  stopTiming(id, success = true, error = null) {
    const timer = this.activeTimers.get(id);
    if (!timer) {
      return null;
    }

    const duration = Date.now() - timer.startTime;
    const performanceData = {
      toolName: timer.toolName,
      duration,
      success,
      error: error?.message,
      timestamp: new Date().toISOString(),
      metadata: timer.metadata
    };

    // Store in tool-specific metrics
    if (!metrics.toolExecutions.has(timer.toolName)) {
      metrics.toolExecutions.set(timer.toolName, {
        count: 0,
        totalDuration: 0,
        successCount: 0,
        failureCount: 0,
        avgDuration: 0,
        maxDuration: 0,
        minDuration: Infinity
      });
    }

    const toolMetrics = metrics.toolExecutions.get(timer.toolName);
    toolMetrics.count++;
    toolMetrics.totalDuration += duration;
    toolMetrics.successCount += success ? 1 : 0;
    toolMetrics.failureCount += success ? 0 : 1;
    toolMetrics.avgDuration = toolMetrics.totalDuration / toolMetrics.count;
    toolMetrics.maxDuration = Math.max(toolMetrics.maxDuration, duration);
    toolMetrics.minDuration = Math.min(toolMetrics.minDuration, duration);

    // Store sample
    metrics.performanceSamples.push(performanceData);
    if (metrics.performanceSamples.length > MAX_PERFORMANCE_SAMPLES) {
      metrics.performanceSamples.shift();
    }

    this.activeTimers.delete(id);
    return performanceData;
  }

  /**
   * Get performance metrics for a specific tool
   */
  getToolMetrics(toolName) {
    return metrics.toolExecutions.get(toolName) || null;
  }

  /**
   * Get all tool performance metrics
   */
  getAllToolMetrics() {
    return Object.fromEntries(metrics.toolExecutions);
  }

  /**
   * Get recent performance samples
   */
  getRecentSamples(limit = 100) {
    return metrics.performanceSamples.slice(-limit);
  }
}

/**
 * Health check functionality
 */
class HealthChecker {
  constructor() {
    this.checks = new Map();
  }

  /**
   * Register a health check
   */
  registerCheck(name, checkFn) {
    this.checks.set(name, checkFn);
  }

  /**
   * Run all health checks
   */
  async runChecks() {
    const results = {};
    let overallHealthy = true;

    for (const [name, checkFn] of this.checks.entries()) {
      try {
        const result = await checkFn();
        results[name] = {
          status: result.healthy ? 'healthy' : 'unhealthy',
          message: result.message,
          timestamp: new Date().toISOString()
        };
        if (!result.healthy) {
          overallHealthy = false;
        }
      } catch (error) {
        results[name] = {
          status: 'error',
          message: error.message,
          timestamp: new Date().toISOString()
        };
        overallHealthy = false;
      }
    }

    return {
      healthy: overallHealthy,
      timestamp: new Date().toISOString(),
      checks: results
    };
  }

  /**
   * Get system resource usage
   */
  getSystemResources() {
    return {
      cpu: {
        usage: os.loadavg()[0],
        cores: os.cpus().length,
        loadAverage: os.loadavg()
      },
      memory: {
        total: os.totalmem(),
        free: os.freemem(),
        used: os.totalmem() - os.freemem(),
        usagePercent: ((os.totalmem() - os.freemem()) / os.totalmem() * 100).toFixed(2)
      },
      uptime: os.uptime(),
      platform: os.platform(),
      arch: os.arch()
    };
  }
}

/**
 * Error tracking and aggregation
 */
class ErrorTracker {
  /**
   * Get recent errors
   */
  getRecentErrors(limit = 50) {
    return metrics.errors.slice(-limit);
  }

  /**
   * Get error statistics
   */
  getErrorStats() {
    const errorCounts = {};
    const componentCounts = {};

    for (const error of metrics.errors) {
      // Count by message pattern
      const pattern = error.message.replace(/\d+/g, 'X'); // Normalize numbers
      errorCounts[pattern] = (errorCounts[pattern] || 0) + 1;

      // Count by component
      componentCounts[error.component] = (componentCounts[error.component] || 0) + 1;
    }

    return {
      total: metrics.errors.length,
      byPattern: errorCounts,
      byComponent: componentCounts,
      recent: metrics.errors.slice(-10)
    };
  }

  /**
   * Clear error history
   */
  clearErrors() {
    metrics.errors = [];
  }
}

// Singleton instances
const performanceMonitor = new PerformanceMonitor();
const healthChecker = new HealthChecker();
const errorTracker = new ErrorTracker();

// Register default health checks
healthChecker.registerCheck('memory', () => {
  const memoryUsage = process.memoryUsage();
  const heapUsedMB = memoryUsage.heapUsed / 1024 / 1024;
  const heapTotalMB = memoryUsage.heapTotal / 1024 / 1024;
  const usagePercent = (heapUsedMB / heapTotalMB) * 100;

  return {
    healthy: usagePercent < 90,
    message: `Heap usage: ${heapUsedMB.toFixed(2)}MB / ${heapTotalMB.toFixed(2)}MB (${usagePercent.toFixed(1)}%)`
  };
});

// Measure real event-loop lag: how long a scheduled continuation waits
// beyond its immediate scheduling. Sustained lag indicates a blocked loop.
healthChecker.registerCheck('event_loop', async () => {
  const start = process.hrtime.bigint();
  await new Promise((resolve) => setImmediate(resolve));
  const lagMs = Number(process.hrtime.bigint() - start) / 1e6;
  return {
    healthy: lagMs < 1000,
    message: `Event loop lag: ${lagMs.toFixed(1)}ms`
  };
});

/**
 * Create a logger for a specific component
 */
export function createLogger(component) {
  return new Logger(component);
}

/**
 * Get the performance monitor instance
 */
export function getPerformanceMonitor() {
  return performanceMonitor;
}

/**
 * Get the health checker instance
 */
export function getHealthChecker() {
  return healthChecker;
}

/**
 * Get the error tracker instance
 */
export function getErrorTracker() {
  return errorTracker;
}

/**
 * Get comprehensive monitoring metrics
 */
export function getMonitoringMetrics() {
  return {
    timestamp: new Date().toISOString(),
    system: healthChecker.getSystemResources(),
    performance: performanceMonitor.getAllToolMetrics(),
    errors: errorTracker.getErrorStats(),
    recentSamples: performanceMonitor.getRecentSamples(20)
  };
}
