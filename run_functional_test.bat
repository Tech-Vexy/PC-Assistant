@echo off
cd C:\Users\Veldrine\Projects\pc_assistant
set AUTO_APPROVE=true
set MCP_ENABLED=false
node -e "
import('./tools.js').then(m => {
  const dispatchTool = m.dispatchTool;
  
  // Test file_organize with a temp folder
  console.log('Testing file_organize...');
  const r1 = await dispatchTool('file_organize', { folderPath: process.cwd(), dryRun: true });
  console.log('  result:', r1.success ? 'OK' : 'FAIL', 'moved:', r1.moved, 'failed:', r1.failed);
  
  // Test file_rename with a temp folder  
  console.log('Testing file_rename...');
  const r2 = await dispatchTool('file_rename', { folderPath: process.cwd(), pattern: '.*', template: '{name}_{index}', dryRun: true });
  console.log('  result:', r2.success ? 'OK' : 'FAIL', 'renamed:', r2.renamed, 'failed:', r2.failed);
  
  // Test file_find
  console.log('Testing file_find...');
  const r3 = await dispatchTool('file_find', { folderPath: process.cwd(), namePattern: 'run_', maxResults: 5 });
  console.log('  result:', r3.success ? 'OK' : 'FAIL', 'found:', r3.count, 'files');
  
  // Test file_convert (should fail gracefully since no LibreOffice)
  console.log('Testing file_convert (expecting error since no LibreOffice)...');
  try {
    const r4 = await dispatchTool('file_convert', { filePath: __filename, targetFormat: 'pdf' });
    console.log('  result:', r4.success ? 'OK' : 'FAIL', 'output:', r4.output || r4.error);
  } catch(e) {
    console.log('  result: ERROR (expected):', e.message);
  }
  
  console.log('\\nAll functional tests complete.');
)"