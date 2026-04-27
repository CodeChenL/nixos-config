# Web KeyboardEvent.code 参考

完整的键盘按键标识符列表，用于 `keyboard` 事件。

## 字母键

| Code | 说明 |
|:---|:---|
| `KeyA` | A 键 |
| `KeyB` | B 键 |
| `KeyC` | C 键 |
| `KeyD` | D 键 |
| `KeyE` | E 键 |
| `KeyF` | F 键 |
| `KeyG` | G 键 |
| `KeyH` | H 键 |
| `KeyI` | I 键 |
| `KeyJ` | J 键 |
| `KeyK` | K 键 |
| `KeyL` | L 键 |
| `KeyM` | M 键 |
| `KeyN` | N 键 |
| `KeyO` | O 键 |
| `KeyP` | P 键 |
| `KeyQ` | Q 键 |
| `KeyR` | R 键 |
| `KeyS` | S 键 |
| `KeyT` | T 键 |
| `KeyU` | U 键 |
| `KeyV` | V 键 |
| `KeyW` | W 键 |
| `KeyX` | X 键 |
| `KeyY` | Y 键 |
| `KeyZ` | Z 键 |

## 数字键

| Code | 说明 |
|:---|:---|
| `Digit0` | 0 键 |
| `Digit1` | 1 键 |
| `Digit2` | 2 键 |
| `Digit3` | 3 键 |
| `Digit4` | 4 键 |
| `Digit5` | 5 键 |
| `Digit6` | 6 键 |
| `Digit7` | 7 键 |
| `Digit8` | 8 键 |
| `Digit9` | 9 键 |

## 功能键

| Code | 说明 |
|:---|:---|
| `F1` | F1 键 |
| `F2` | F2 键 |
| `F3` | F3 键 |
| `F4` | F4 键 |
| `F5` | F5 键 |
| `F6` | F6 键 |
| `F7` | F7 键 |
| `F8` | F8 键 |
| `F9` | F9 键 |
| `F10` | F10 键 |
| `F11` | F11 键 |
| `F12` | F12 键 |

## 控制键

| Code | 说明 |
|:---|:---|
| `Escape` | ESC 键 |
| `Tab` | Tab 键 |
| `CapsLock` | 大写锁定 |
| `ShiftLeft` | 左 Shift |
| `ShiftRight` | 右 Shift |
| `ControlLeft` | 左 Ctrl |
| `ControlRight` | 右 Ctrl |
| `AltLeft` | 左 Alt |
| `AltRight` | 右 Alt |
| `MetaLeft` | 左 Meta (Windows/Command) |
| `MetaRight` | 右 Meta |
| `Space` | 空格键 |
| `Enter` | 回车键 |
| `Backspace` | 退格键 |
| `Delete` | 删除键 |
| `Insert` | 插入键 |
| `Home` | Home 键 |
| `End` | End 键 |
| `PageUp` | 上翻页 |
| `PageDown` | 下翻页 |

## 方向键

| Code | 说明 |
|:---|:---|
| `ArrowUp` | 上箭头 |
| `ArrowDown` | 下箭头 |
| `ArrowLeft` | 左箭头 |
| `ArrowRight` | 右箭头 |

## 符号键

| Code | 说明 |
|:---|:---|
| `Backquote` | `` ` `` |
| `Minus` | `-` |
| `Equal` | `=` |
| `BracketLeft` | `[` |
| `BracketRight` | `]` |
| `Backslash` | `\` |
| `Semicolon` | `;` |
| `Quote` | `'` |
| `Comma` | `,` |
| `Period` | `.` |
| `Slash` | `/` |

## 小键盘

| Code | 说明 |
|:---|:---|
| `NumLock` | 数字锁定 |
| `Numpad0` ~ `Numpad9` | 数字键 0-9 |
| `NumpadAdd` | `+` |
| `NumpadSubtract` | `-` |
| `NumpadMultiply` | `*` |
| `NumpadDivide` | `/` |
| `NumpadDecimal` | `.` |
| `NumpadEnter` | 回车 |

## 常用组合键示例

| 功能 | 事件序列 |
|:---|:---|
| **复制** | `["keyboard", "ControlLeft", true]`, `["keyboard", "KeyC", true]`, `["delay", 50]`, `["keyboard", "KeyC", false]`, `["keyboard", "ControlLeft", false]` |
| **粘贴** | `["keyboard", "ControlLeft", true]`, `["keyboard", "KeyV", true]`, `["delay", 50]`, `["keyboard", "KeyV", false]`, `["keyboard", "ControlLeft", false]` |
| **全选** | `["keyboard", "ControlLeft", true]`, `["keyboard", "KeyA", true]`, `["delay", 50]`, `["keyboard", "KeyA", false]`, `["keyboard", "ControlLeft", false]` |
| **保存** | `["keyboard", "ControlLeft", true]`, `["keyboard", "KeyS", true]`, `["delay", 50]`, `["keyboard", "KeyS", false]`, `["keyboard", "ControlLeft", false]` |
| **运行** | `["keyboard", "MetaLeft", true]`, `["keyboard", "KeyR", true]`, `["delay", 50]`, `["keyboard", "KeyR", false]`, `["keyboard", "MetaLeft", false]` |
| **任务管理器** | `["keyboard", "ControlLeft", true]`, `["keyboard", "ShiftLeft", true]`, `["keyboard", "Escape", true]`, ... |
| **Alt+Tab** | `["keyboard", "AltLeft", true]`, `["keyboard", "Tab", true]`, `["delay", 50]`, `["keyboard", "Tab", false]`, `["keyboard", "AltLeft", false]` |
| **截图** | `["keyboard", "MetaLeft", true]`, `["keyboard", "ShiftLeft", true]`, `["keyboard", "KeyS", true]`, ... |

## 参考链接

- [MDN - KeyboardEvent.code](https://developer.mozilla.org/en-US/docs/Web/API/KeyboardEvent/code)
- [W3C - UI Events KeyboardEvent code Values](https://www.w3.org/TR/uievents-code/)
