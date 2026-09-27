import { mouse, keyboard, Key, Button } from '@nut-tree-fork/nut-js';

// Move mouse to specific coordinates
export async function moveMouse(args) {
  const { x, y } = args;

  try {
    await mouse.setPosition({ x: x, y: y });
    return {
      success: true,
      message: `Mouse moved to coordinates (${x}, ${y})`
    };
  } catch (error) {
    throw new Error(`Failed to move mouse: ${error.message}`);
  }
}

// Click mouse button at current position or optional coordinates
export async function clickMouse(args = {}) {
  const { button = 'left', double = false, x, y } = args;

  try {
    if (typeof x === 'number' && typeof y === 'number') {
      await mouse.setPosition({ x, y });
    }
    const btn = String(button).toLowerCase();
    if (double) {
      await mouse.doubleClick(btn === 'right' ? Button.RIGHT : btn === 'middle' ? Button.MIDDLE : Button.LEFT);
    } else if (btn === 'right') {
      await mouse.rightClick();
    } else if (btn === 'middle') {
      await mouse.click(Button.MIDDLE);
    } else {
      await mouse.leftClick();
    }
    return {
      success: true,
      message: `Mouse ${double ? 'double clicked' : 'clicked'} (${btn})${typeof x === 'number' && typeof y === 'number' ? ` at (${x}, ${y})` : ''}`
    };
  } catch (error) {
    throw new Error(`Failed to click mouse: ${error.message}`);
  }
}

// Type text at current cursor position
export async function typeText(args) {
  const { text } = args;

  try {
    await keyboard.type(text);
    return {
      success: true,
      message: `Typed: ${text}`
    };
  } catch (error) {
    throw new Error(`Failed to type text: ${error.message}`);
  }
}

// Press keyboard keys or shortcuts
export async function pressKeys(args) {
  const { keys } = args;

  try {
    // Parse key combination (e.g., "ctrl+c", "enter", "alt+tab")
    const keyParts = keys.toLowerCase().split('+');
    const keysToPress = [];

    for (const part of keyParts) {
      switch (part) {
        case 'ctrl':
        case 'control':
          keysToPress.push(Key.LeftControl);
          break;
        case 'alt':
          keysToPress.push(Key.LeftAlt);
          break;
        case 'shift':
          keysToPress.push(Key.LeftShift);
          break;
        case 'cmd':
        case 'command':
        case 'win':
          keysToPress.push(Key.LeftWin);
          break;
        case 'enter':
        case 'return':
          keysToPress.push(Key.Enter);
          break;
        case 'space':
          keysToPress.push(Key.Space);
          break;
        case 'tab':
          keysToPress.push(Key.Tab);
          break;
        case 'esc':
        case 'escape':
          keysToPress.push(Key.Escape);
          break;
        case 'backspace':
          keysToPress.push(Key.Backspace);
          break;
        case 'delete':
          keysToPress.push(Key.Delete);
          break;
        case 'up':
          keysToPress.push(Key.Up);
          break;
        case 'down':
          keysToPress.push(Key.Down);
          break;
        case 'left':
          keysToPress.push(Key.Left);
          break;
        case 'right':
          keysToPress.push(Key.Right);
          break;
        case 'f1':
          keysToPress.push(Key.F1);
          break;
        case 'f2':
          keysToPress.push(Key.F2);
          break;
        case 'f3':
          keysToPress.push(Key.F3);
          break;
        case 'f4':
          keysToPress.push(Key.F4);
          break;
        case 'f5':
          keysToPress.push(Key.F5);
          break;
        case 'f6':
          keysToPress.push(Key.F6);
          break;
        case 'f7':
          keysToPress.push(Key.F7);
          break;
        case 'f8':
          keysToPress.push(Key.F8);
          break;
        case 'f9':
          keysToPress.push(Key.F9);
          break;
        case 'f10':
          keysToPress.push(Key.F10);
          break;
        case 'f11':
          keysToPress.push(Key.F11);
          break;
        case 'f12':
          keysToPress.push(Key.F12);
          break;
        default:
          // Check single alphanumeric character (e.g. 'c' in ctrl+c, '1' etc)
          if (part.length === 1) {
            const upper = part.toUpperCase();
            if (Key[upper] !== undefined) {
              keysToPress.push(Key[upper]);
              break;
            }
            if (/^[0-9]$/.test(part) && Key[`Num${part}`] !== undefined) {
              keysToPress.push(Key[`Num${part}`]);
              break;
            }
          }
          if (Key[part] !== undefined) {
            keysToPress.push(Key[part]);
          }
      }
    }

    if (keysToPress.length === 0) {
      throw new Error(`No recognized keys found in combination: ${keys}`);
    }

    await keyboard.pressKey(...keysToPress);
    await keyboard.releaseKey(...keysToPress);

    return {
      success: true,
      message: `Pressed keys: ${keys}`
    };
  } catch (error) {
    throw new Error(`Failed to press keys: ${error.message}`);
  }
}