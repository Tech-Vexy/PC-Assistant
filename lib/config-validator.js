/**
 * Configuration validation and defaults
 * 
 * This module provides validation for environment variables and configuration values,
 * ensuring that required settings are present and valid before the application starts.
 * It also provides sensible defaults for optional configuration values.
 * 
 * All validation functions return structured error information that can be used
 * to provide helpful error messages to users during setup.
 */

import dotenv from 'dotenv';

// Load environment variables
dotenv.config();

/**
 * Configuration schema definition
 * Each field defines validation rules and default values
 */
const CONFIG_SCHEMA = {
  // Required API keys
  ASSEMBLYAI_API_KEY: {
    required: true,
    description: 'AssemblyAI API key for voice processing',
    pattern: /^.{20,}$/,
    errorMessage: 'Must be at least 20 characters'
  },
  
  // LLM configuration (at least one required)
  LLM_API_KEY: {
    required: false, // Not strictly required if using stored agent LLM
    description: 'OpenRouter API key for LLM provider',
    pattern: /^.{20,}$/,
    errorMessage: 'Must be at least 20 characters'
  },
  
  OPENAI_API_KEY: {
    required: false,
    description: 'OpenAI API key (fallback LLM provider)',
    pattern: /^sk-[a-zA-Z0-9]{20,}$/,
    errorMessage: 'Must be a valid OpenAI API key format'
  },
  
  LLM_BASE_URL: {
    required: false,
    description: 'Custom LLM base URL (for local LLMs)',
    pattern: /^https?:\/\/.+/,
    errorMessage: 'Must be a valid HTTP/HTTPS URL',
    defaultValue: 'https://openrouter.ai/api/v1'
  },
  
  // Google OAuth (optional but recommended for Gmail/Calendar)
  GOOGLE_CLIENT_ID: {
    required: false,
    description: 'Google OAuth client ID',
    pattern: /^[a-zA-Z0-9-]+\.apps\.googleusercontent\.com$/,
    errorMessage: 'Must be a valid Google client ID format'
  },
  
  GOOGLE_CLIENT_SECRET: {
    required: false,
    description: 'Google OAuth client secret',
    pattern: /^.{10,}$/,
    errorMessage: 'Must be at least 10 characters'
  },
  
  // Computer Use (optional but recommended for UI automation)
  GEMINI_API_KEY: {
    required: false,
    description: 'Gemini API key for computer use vision',
    pattern: /^.{20,}$/,
    errorMessage: 'Must be at least 20 characters'
  },
  
  // Server configuration
  PORT: {
    required: false,
    description: 'Server port number',
    pattern: /^[1-9][0-9]{0,4}$/,
    min: 1024,
    max: 65535,
    errorMessage: 'Must be a valid port number (1024-65535)',
    defaultValue: '3000'
  },
  
  // Audio configuration
  AUDIO_DEVICE: {
    required: false,
    description: 'Audio capture device name',
    pattern: /^.{1,255}$/,
    errorMessage: 'Must be 1-255 characters',
    defaultValue: 'default'
  },
  
  BARGE_IN_THRESHOLD: {
    required: false,
    description: 'Audio energy threshold for barge-in detection (0 to disable)',
    pattern: /^\d+$/,
    min: 0,
    max: 20000,
    errorMessage: 'Must be a number between 0 and 20000',
    defaultValue: '8000'
  },
  
  // Computer Use configuration
  COMPUTER_USE_ENVIRONMENT: {
    required: false,
    description: 'Computer use environment (desktop or browser)',
    pattern: /^(desktop|browser)$/,
    errorMessage: 'Must be either "desktop" or "browser"',
    defaultValue: 'desktop'
  },
  
  COMPUTER_USE_MAX_STEPS: {
    required: false,
    description: 'Maximum steps for computer use tasks',
    pattern: /^\d+$/,
    min: 1,
    max: 50,
    errorMessage: 'Must be a number between 1 and 50',
    defaultValue: '20'
  },
  
  COMPUTER_USE_STEP_TIMEOUT_MS: {
    required: false,
    description: 'Timeout per computer use step in milliseconds',
    pattern: /^\d+$/,
    min: 5000,
    max: 120000,
    errorMessage: 'Must be a number between 5000 and 120000',
    defaultValue: '30000'
  },
  
  COMPUTER_USE_ENABLE_PROMPT_INJECTION_DETECTION: {
    required: false,
    description: 'Enable prompt injection detection for computer use screenshots',
    pattern: /^(true|false)$/,
    errorMessage: 'Must be either "true" or "false"',
    defaultValue: 'true'
  },
  
  COMPUTER_USE_DISABLED_SAFETY_POLICIES: {
    required: false,
    description: 'Comma-separated list of safety policies to disable (e.g., DATA_MODIFICATION,FINANCIAL_TRANSACTIONS)',
    pattern: /^[A-Z_]+(,[A-Z_]+)*$/,
    errorMessage: 'Must be comma-separated uppercase policy names',
    defaultValue: ''
  },
  
  COMPUTER_USE_EXCLUDED_FUNCTIONS: {
    required: false,
    description: 'Comma-separated list of predefined functions to exclude (e.g., click,scroll)',
    pattern: /^[a-z_]+(,[a-z_]+)*$/,
    errorMessage: 'Must be comma-separated lowercase function names',
    defaultValue: ''
  },
  
  GEMINI_VISION_MODEL: {
    required: false,
    description: 'Gemini model for computer use',
    pattern: /^gemini-.+$/,
    errorMessage: 'Must be a valid Gemini model name',
    defaultValue: 'gemini-3.8-flash'
  },
  
  // Security configuration
  AUTO_APPROVE: {
    required: false,
    description: 'Auto-approve dangerous tools',
    pattern: /^(true|false)$/,
    errorMessage: 'Must be either "true" or "false"',
    defaultValue: 'true'
  },
  
  SCREEN_VERIFY: {
    required: false,
    description: 'Enable screen verification for device control',
    pattern: /^(true|false)$/,
    errorMessage: 'Must be either "true" or "false"',
    defaultValue: 'false'
  },
  
  // Wake word configuration
  WAKEWORD_ENGINE: {
    required: false,
    description: 'Wake word detection engine',
    pattern: /^(auto|openwakeword|sherpa|energy)$/,
    errorMessage: 'Must be one of: auto, openwakeword, sherpa, energy',
    defaultValue: 'auto'
  },
  
  WAKEWORD_THRESHOLD: {
    required: false,
    description: 'Wake word detection threshold',
    pattern: /^0\.\d+$/,
    min: 0.1,
    max: 0.9,
    errorMessage: 'Must be a decimal between 0.1 and 0.9',
    defaultValue: '0.5'
  }
};

/**
 * Validate a single configuration value against its schema
 * @param {string} key - Configuration key
 * @param {string} value - Configuration value
 * @returns {Object} Validation result with ok flag and error message
 */
function validateConfigValue(key, value) {
  const schema = CONFIG_SCHEMA[key];
  if (!schema) {
    return { ok: true, warning: `Unknown configuration key: ${key}` };
  }
  
  // Check if required and missing
  if (schema.required && (!value || value.trim() === '')) {
    return { 
      ok: false,
      missing: true,
      error: `${key} is required: ${schema.description}` 
    };
  }
  
  // If not required and missing, use default if available
  if (!value || value.trim() === '') {
    if (schema.defaultValue !== undefined) {
      return { ok: true, usingDefault: true, defaultValue: schema.defaultValue };
    }
    return { ok: true }; // Optional field not provided
  }
  
  // Validate pattern if specified
  if (schema.pattern && !schema.pattern.test(value)) {
    return { 
      ok: false, 
      error: `${key} validation failed: ${schema.errorMessage}` 
    };
  }
  
  // Validate numeric ranges
  if (schema.min !== undefined || schema.max !== undefined) {
    const numValue = Number(value);
    if (isNaN(numValue)) {
      return { 
        ok: false, 
        error: `${key} must be a number` 
      };
    }
    if (schema.min !== undefined && numValue < schema.min) {
      return { 
        ok: false, 
        error: `${key} must be at least ${schema.min}` 
      };
    }
    if (schema.max !== undefined && numValue > schema.max) {
      return { 
        ok: false, 
        error: `${key} must be at most ${schema.max}` 
      };
    }
  }
  
  return { ok: true };
}

/**
 * Validate all configuration values
 * @param {Object} config - Configuration object (defaults to process.env)
 * @returns {Object} Validation result with errors, warnings, and defaults used
 */
export function validateConfiguration(config = process.env) {
  const missing = [];
  const invalid = [];
  const warnings = [];
  const defaultsUsed = [];
  const validatedConfig = {};
  
  for (const [key, schema] of Object.entries(CONFIG_SCHEMA)) {
    const value = config[key];
    const validation = validateConfigValue(key, value);
    
    if (!validation.ok) {
      if (validation.missing) {
        missing.push(validation.error);
      } else {
        invalid.push(validation.error);
      }
      continue;
    }
    
    if (validation.warning) {
      warnings.push(validation.warning);
    }
    
    if (validation.usingDefault) {
      defaultsUsed.push({ key, defaultValue: validation.defaultValue });
      validatedConfig[key] = validation.defaultValue;
    } else {
      validatedConfig[key] = value;
    }
  }
  
  // Check that at least one LLM provider is configured
  const hasLlmProvider = config.LLM_API_KEY || config.OPENAI_API_KEY || config.LLM_BASE_URL;
  if (!hasLlmProvider) {
    warnings.push('No LLM provider configured - will use stored agent LLM if available');
  }
  
  return {
    ok: missing.length === 0 && invalid.length === 0,
    errors: [...missing, ...invalid],
    missing,
    invalid,
    warnings,
    defaultsUsed,
    config: validatedConfig
  };
}

/**
 * Get validated configuration with defaults applied
 * @returns {Object} Validated configuration object
 */
export function getValidatedConfig() {
  const validation = validateConfiguration();
  return validation.config;
}

/**
 * Check if configuration is valid for startup
 * @returns {boolean} True if configuration is valid for startup
 */
export function isConfigurationValid() {
  const validation = validateConfiguration();
  return validation.ok;
}

/**
 * Get configuration errors for display
 * @returns {Array<string>} Array of error messages
 */
export function getConfigurationErrors() {
  const validation = validateConfiguration();
  return validation.errors;
}

/**
 * Get configuration warnings for display
 * @returns {Array<string>} Array of warning messages
 */
export function getConfigurationWarnings() {
  const validation = validateConfiguration();
  return validation.warnings;
}

/**
 * Apply defaults to a configuration object
 * @param {Object} config - Configuration object to apply defaults to
 * @returns {Object} Configuration with defaults applied
 */
export function applyDefaults(config = {}) {
  const result = { ...config };
  for (const [key, schema] of Object.entries(CONFIG_SCHEMA)) {
    if (schema.defaultValue !== undefined && (result[key] === undefined || result[key] === '')) {
      result[key] = schema.defaultValue;
    }
  }
  return result;
}

/**
 * Get required configuration keys
 * @returns {Array<string>} Array of required configuration keys
 */
export function getRequiredKeys() {
  return Object.entries(CONFIG_SCHEMA)
    .filter(([_, schema]) => schema.required)
    .map(([key, _]) => key);
}

/**
 * Get optional configuration keys
 * @returns {Array<string>} Array of optional configuration keys
 */
export function getOptionalKeys() {
  return Object.entries(CONFIG_SCHEMA)
    .filter(([_, schema]) => !schema.required)
    .map(([key, _]) => key);
}

/**
 * Get configuration description for a key
 * @param {string} key - Configuration key
 * @returns {Object|null} Configuration schema or null if not found
 */
export function getConfigDescription(key) {
  return CONFIG_SCHEMA[key] || null;
}