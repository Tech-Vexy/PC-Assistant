// Configuration validator tests
import { describe, it } from 'node:test';
import assert from 'node:assert/strict';

describe('configuration validator', () => {
  it('validates required configuration fields', async () => {
    const { validateConfiguration } = await import('../lib/config-validator.js');
    
    // Test with missing required field
    const result = validateConfiguration({ 
      ASSEMBLYAI_API_KEY: '' 
    });
    assert.equal(result.ok, false);
    assert.ok(result.errors.some(e => e.includes('ASSEMBLYAI_API_KEY')));
  });

  it('applies defaults for optional fields', async () => {
    const { validateConfiguration } = await import('../lib/config-validator.js');
    
    const result = validateConfiguration({
      ASSEMBLYAI_API_KEY: 'test_key_12345678901234567890'
    });
    
    assert.equal(result.ok, true);
    assert.ok(result.defaultsUsed.length > 0);
    assert.ok(result.defaultsUsed.some(d => d.key === 'PORT'));
  });

  it('validates port number range', async () => {
    const { validateConfiguration } = await import('../lib/config-validator.js');
    
    const invalidPort = validateConfiguration({
      ASSEMBLYAI_API_KEY: 'test_key_12345678901234567890',
      PORT: '99999'
    });
    assert.equal(invalidPort.ok, false);
    assert.ok(invalidPort.errors.some(e => e.includes('PORT')));
  });

  it('validates LLM base URL format', async () => {
    const { validateConfiguration } = await import('../lib/config-validator.js');
    
    const invalidUrl = validateConfiguration({
      ASSEMBLYAI_API_KEY: 'test_key_12345678901234567890',
      LLM_BASE_URL: 'not-a-url'
    });
    assert.equal(invalidUrl.ok, false);
    assert.ok(invalidUrl.errors.some(e => e.includes('LLM_BASE_URL')));
  });

  it('validates computer use environment', async () => {
    const { validateConfiguration } = await import('../lib/config-validator.js');
    
    const invalidEnv = validateConfiguration({
      ASSEMBLYAI_API_KEY: 'test_key_12345678901234567890',
      COMPUTER_USE_ENVIRONMENT: 'invalid_env'
    });
    assert.equal(invalidEnv.ok, false);
    assert.ok(invalidEnv.errors.some(e => e.includes('COMPUTER_USE_ENVIRONMENT')));
  });

  it('accepts valid configuration', async () => {
    const { validateConfiguration } = await import('../lib/config-validator.js');
    
    const validConfig = validateConfiguration({
      ASSEMBLYAI_API_KEY: 'test_key_12345678901234567890',
      LLM_API_KEY: 'llm_key_12345678901234567890',
      PORT: '3000',
      COMPUTER_USE_ENVIRONMENT: 'desktop'
    });
    
    assert.equal(validConfig.ok, true);
    assert.equal(validConfig.errors.length, 0);
  });

  it('provides configuration schema information', async () => {
    const { getConfigDescription, getRequiredKeys, getOptionalKeys } = await import('../lib/config-validator.js');
    
    const portDesc = getConfigDescription('PORT');
    assert.ok(portDesc);
    assert.equal(portDesc.description, 'Server port number');
    
    const requiredKeys = getRequiredKeys();
    assert.ok(requiredKeys.includes('ASSEMBLYAI_API_KEY'));
    
    const optionalKeys = getOptionalKeys();
    assert.ok(optionalKeys.includes('PORT'));
  });

  it('applies defaults to configuration object', async () => {
    const { applyDefaults } = await import('../lib/config-validator.js');
    
    const config = applyDefaults({ ASSEMBLYAI_API_KEY: 'test_key_12345678901234567890' });
    assert.equal(config.PORT, '3000');
    assert.equal(config.AUDIO_DEVICE, 'default');
  });
});