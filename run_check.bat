@echo off
cd C:\Users\Veldrine\Projects\pc_assistant
node -e "import('./tools.js').then(m => { const tools = m.buildAllTools(); console.log('Tools loaded:', tools.length); const names = tools.map(t => t.name); console.log('File_ tools:', names.filter(n => n.startsWith('file_')).join(', ')); })"