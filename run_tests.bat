@echo off
cd C:\Users\Veldrine\Projects\pc_assistant
node --test tests/tools.test.js > test_output.txt 2>&1
echo.
echo === TEST OUTPUT ===
type test_output.txt