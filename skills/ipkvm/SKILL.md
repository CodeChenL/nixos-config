---
name: ipkvm
description: >
  通过HTTP API远程控制IPKVM设备，实现对被控机的屏幕截图获取、鼠标键盘自动化操作。
  适用于远程服务器管理、自动化测试、无人值守运维等场景。
  支持绝对/相对坐标鼠标控制、键盘按键模拟、文本输入和延时等待。
metadata: { "openclaw": { "emoji": "🖥️", "requires": { "bins": ["python3"]}}}
---

# IPKVM 远程控制器

OpenClaw 通过调用 IPKVM 提供的 HTTP 接口（屏幕截图、键盘与鼠标控制），实现被控机的远程自动化操作。

## 系统架构

```
┌─────────────┐    HTTP API    ┌─────────────┐    KVM信号    ┌─────────────┐
│  OpenClaw   │◄──────────────►│    IPKVM    │◄─────────────►│   被控机    │
│  (PC机)     │                │             │               │             │
└─────────────┘                └─────────────┘               └─────────────┘
                                    │
                                    ├─ 截图接口 (/api/snapshot)
                                    └─ 控制接口 (/api/control)
```

## 环境配置

```bash
export IPKVM_URL="http://192.168.2.245:8080"
```

## 环境配置

> **重要**：首次使用前，先在 PowerShell 中运行：
> ```powershell
> [System.Environment]::SetEnvironmentVariable("IPKVM_URL", "http://192.168.2.245:8080", "User")
> ```


## API 接口

### 1. 屏幕截图

获取被控机实时屏幕图像，供AI模型分析决策。

| 属性 | 值 |
|:---|:---|
| URL | `${IPKVM_URL}/api/snapshot` |
| 方法 | GET |
| 返回 | JPEG 图像二进制数据 |

**示例**:
```bash
curl -X GET "${IPKVM_URL}/api/snapshot" -o screen.jpeg
```

### 2. 设备控制

发送鼠标、键盘、文本输入等控制指令序列。

| 属性 | 值 |
|:---|:---|
| URL | `${IPKVM_URL}/api/control` |
| 方法 | POST |
| Content-Type | `application/json` |

**请求体**:
```json
{
  "events": [
    ["text", "Hello World"],
    ["delay", 300],
    ["mouse_abs", 0, 0.5, 0.5, 0, 0],
    ["keyboard", "MetaLeft", true],
    ["keyboard", "MetaLeft", false]
  ]
}
```

**响应**:
```json
{
  "code": 0,
  "data": null,
  "message": "Request succeeded!"
}
```

- `code`: 0 表示成功，非零表示失败
- `message`: 返回IPKVM调试信息

## 事件类型详解

### 键盘事件 (keyboard)

模拟键盘按键的按下与释放。

**格式**: `["keyboard", keyCode, isPressed]`

| 索引 | 字段 | 类型 | 说明 |
|:---|:---|:---|:---|
| 0 | `type` | `string` | 固定值 `"keyboard"` |
| 1 | `keyCode` | `string` | 按键标识符，采用 [Web标准 KeyboardEvent.code](https://developer.mozilla.org/en-US/docs/Web/API/KeyboardEvent/code) |
| 2 | `isPressed` | `boolean` | `true`=按下，`false`=释放 |

**常用按键标识符**:

| 标识符 | 说明 |
|:---|:---|
| `MetaLeft` | 左 Meta 键（Windows键/Command键） |
| `ControlLeft` | 左 Ctrl 键 |
| `AltLeft` | 左 Alt 键 |
| `ShiftLeft` | 左 Shift 键 |
| `KeyA` ~ `KeyZ` | 字母键 A-Z |
| `Enter` | 回车键 |
| `Escape` | ESC 键 |
| `Tab` | Tab 键 |
| `Space` | 空格键 |

**示例**:
```json
["keyboard", "MetaLeft", true]   // 按下 Windows 键
["keyboard", "MetaLeft", false]  // 释放 Windows 键
["keyboard", "KeyR", true]       // 按下 R 键
["keyboard", "KeyR", false]    // 释放 R 键
```

### 绝对坐标鼠标事件 (mouse_abs)

移动鼠标到屏幕绝对位置。

**格式**: `["mouse_abs", buttons, x, y, wheelY, wheelX]`

| 索引 | 字段 | 类型 | 说明 |
|:---|:---|:---|:---|
| 0 | `type` | `string` | 固定值 `"mouse_abs"` |
| 1 | `buttons` | `number` | 鼠标按键状态（位掩码） |
| 2 | `x` | `number` | 绝对坐标 X，`[0.00, 1.00]`，左上角为原点 |
| 3 | `y` | `number` | 绝对坐标 Y，`[0.00, 1.00]`，左上角为原点 |
| 4 | `wheelY` | `number` | 垂直滚轮，`[-20, 20]`，正值向下滚动 |
| 5 | `wheelX` | `number` | 水平滚轮，`[-20, 20]`，正值向右滚动 |

**按键位掩码**:
- `0`: 无按键 / 释放所有按键
- `1` (bit 0): 左键
- `2` (bit 1): 右键  
- `4` (bit 2): 中键
- `3` (1+2): 同时按下左键和右键

**示例**:
```json
["mouse_abs", 0, 0.5, 0.5, 0, 0]      // 移动鼠标到屏幕中心
["mouse_abs", 1, 0.5, 0.5, 0, 0]      // 移动到中心并点击左键
["mouse_abs", 0, 0.5, 0.5, 0, 0]      // 移动到中心并释放按键
["mouse_abs", 0, 0.5, 0.5, 20, 10]    // 移动到中心，垂直向下滚动20px，水平向右滚动10px
```

### 相对坐标鼠标事件 (mouse_rel)

从当前位置相对移动鼠标，单位为像素。

**格式**: `["mouse_rel", buttons, deltaX, deltaY, wheelY, wheelX]`

| 索引 | 字段 | 类型 | 说明 |
|:---|:---|:---|:---|
| 0 | `type` | `string` | 固定值 `"mouse_rel"` |
| 1 | `buttons` | `number` | 鼠标按键状态（位掩码，同 `mouse_abs`） |
| 2 | `deltaX` | `number` | X轴相对位移（像素），正值向右，负值向左 |
| 3 | `deltaY` | `number` | Y轴相对位移（像素），正值向下，负值向上 |
| 4 | `wheelY` | `number` | 垂直滚轮，`[-20, 20]`，正值向下滚动 |
| 5 | `wheelX` | `number` | 水平滚轮，`[-20, 20]`，正值向右滚动 |

**示例**:
```json
["mouse_rel", 0, 10, 10, 0, 0]        // 从当前位置，向右和向下各平移 10 像素
["mouse_rel", 1, 0, 0, 0, 0]          // 在鼠标当前位置点击左键
["mouse_rel", 0, 0, 0, 0, 0]          // 在鼠标当前位置松开上次操作的鼠标按键
["mouse_rel", 0, 10, 10, 20, 10]      // 右下移10px，同时垂直向下滚动20px，水平向右滚动10px
```

### 文本事件 (text)

在当前光标位置输入文本字符串。

**格式**: `["text", "text_to_type"]`

| 索引 | 字段 | 类型 | 说明 |
|:---|:---|:---|:---|
| 0 | `type` | `string` | 固定值 `"text"` |
| 1 | `content` | `string` | 输入文本，最长1024字符 |

**字符集限制**:
- 控制字符：`9` (Tab)、`10` (Enter)
- 可打印字符：`32` (Space) ~ `126` (`~`)

**示例**:
```json
["text", "https://www.baidu.com"]  // 在当前光标位置输入网址
```

### 暂停事件 (delay)

暂停执行，确保 IPKVM 完成前一个操作。

**格式**: `["delay", milliseconds]`

| 索引 | 字段 | 类型 | 说明 |
|:---|:---|:---|:---|
| 0 | `type` | `string` | 固定值 `"delay"` |
| 1 | `duration` | `number` | 暂停时长，单位：毫秒 |

> **重要提示**：
> - 在 `text` 事件后**必须**添加 `delay` 事件，确保文本完整输入
> - 文本长度约30字符时，建议暂停 **1000毫秒**
> - 长文本需要分段输入，每30字符后添加暂停
> - 复杂操作需多次发送 `delay`

**示例**:
```json
["text", "https://www.baidu.com"]  // 输入文本（长度约30）
["delay", 1000]                     // 暂停1000毫秒，确保文本输出完整
```

## 完整任务示例

### 打开浏览器访问百度

```json
{
  "events": [
    ["keyboard", "MetaLeft", true],
    ["keyboard", "KeyR", true],
    ["delay", 50],
    ["keyboard", "KeyR", false],
    ["keyboard", "MetaLeft", false],
    ["delay", 500],
    ["text", "chrome"],
    ["delay", 300],
    ["keyboard", "Enter", true],
    ["keyboard", "Enter", false],
    ["delay", 3000],
    ["mouse_abs", 0, 0.5, 0.08, 0, 0],
    ["delay", 200],
    ["text", "baidu.com"],
    ["delay", 1000],
    ["keyboard", "Enter", true],
    ["keyboard", "Enter", false]
  ]
}
```

**步骤分解**:
1. `Win+R` 打开运行对话框
2. 输入 `chrome` 并回车启动浏览器
3. 等待 3 秒确保浏览器启动
4. 移动鼠标到地址栏（顶部中心）
5. 输入 `baidu.com`（约9字符，但建议1000ms确保完整）
6. 暂停1000毫秒确保文本输入完整
7. 回车访问

## 最佳实践

### 1. 坐标定位策略
- 优先使用 `mouse_abs`（绝对坐标），坐标范围 `[0.00, 1.00]` 适配不同分辨率
- 关键操作前获取截图确认当前状态
- 界面元素定位建议结合AI视觉分析

### 2. 时序控制（重要）

| 场景 | 建议延时 | 说明 |
|:---|:---|:---|
| 短文本输入后 (<10字符) | 300ms | 简单文本 |
| 中等文本输入后 (10-30字符) | 500-800ms | 如网址 |
| **长文本输入后 (约30字符)** | **1000ms** | 必须暂停确保完整 |
| 程序启动后 | 2000-5000ms | 视程序启动时间 |
| 页面加载后 | 1000-3000ms | 视网络情况 |
| 连续按键间 | 50-100ms | 防丢键 |

### 3. 长文本输入策略

文本长度超过30字符时，必须分段输入：

```json
{
  "events": [
    ["text", "This is a long text that needs"],
    ["delay", 1000],
    ["text", " to be split into multiple parts"],
    ["delay", 1000],
    ["text", " to ensure complete input."],
    ["delay", 1000]
  ]
}
```

### 4. 按键操作规范
- 必须成对出现：`[key, true]`（按下）和 `[key, false]`（释放）
- 组合键顺序：先按修饰键（Ctrl/Alt/Shift/Win），再按主键
- 释放顺序：先释主键，再释放修饰键

### 5. 滚轮操作
- 垂直滚轮 `wheelY`: `[-20, 20]`，正值向下滚动
- 水平滚轮 `wheelX`: `[-20, 20]`，正值向右滚动

### 6. 错误处理
- 检查 `code` 字段，非零值表示失败
- 截图获取失败时检查网络连接和IPKVM状态
- 控制无响应时验证JSON格式和事件参数

## 故障排查

| 现象 | 可能原因 | 解决方案 |
|:---|:---|:---|
| 截图获取失败 | 网络不通/IPKVM未启动 | 检查 `IPKVM_URL` 网络连通性 |
| 控制无响应 | 事件格式错误 | 验证JSON数组长度和类型 |
| 坐标定位不准 | 分辨率变化 | 使用 `mouse_abs` 绝对坐标 `[0.00, 1.00]` |
| 文本输入乱码 | 输入法状态异常 | 先切换至英文输入法 |
| 文本输入不完整 | 延时不足 | 每30字符后添加1000ms暂停 |
| 操作顺序错乱 | 延时不足 | 增加 `delay` 时长 |
| 长文本截断 | 缓冲区溢出 | 分段输入，每30字符后暂停 |

## 辅助脚本

### Bash 快速调用

```bash
#!/bin/bash
# scripts/send_control.sh

IPKVM_URL="${IPKVM_URL:-http://192.168.2.224:8080}"

curl -X POST "${IPKVM_URL}/api/control" \
  -H "Content-Type: application/json" \
  -d "$1"
```

### Python 封装

```python
#!/usr/bin/env python3
# scripts/ipkvm_client.py

import os
import requests
from typing import List, Union

class IPKVMClient:
    def __init__(self):
        self.url = os.getenv('IPKVM_URL', 'http://192.168.2.224:8080')

    def screenshot(self, save_path: str = "screen.jpeg") -> bytes:
        resp = requests.get(f"{self.url}/api/snapshot", timeout=10)
        if save_path:
            with open(save_path, 'wb') as f:
                f.write(resp.content)
        return resp.content

    def control(self, events: List[List[Union[str, int, float, bool]]]) -> dict:
        resp = requests.post(
            f"{self.url}/api/control",
            json={"events": events},
            headers={"Content-Type": "application/json"},
            timeout=30
        )
        return resp.json()

    def text(self, content: str) -> dict:
        # 自动分段：每30字符后添加1000ms暂停
        events = []
        chunk_size = 30
        for i in range(0, len(content), chunk_size):
            chunk = content[i:i+chunk_size]
            events.append(["text", chunk])
            events.append(["delay", 1000])
        return self.control(events)
```

## 相关资源

- **scripts/**: 封装常用操作的辅助脚本
- **examples/**: 典型自动化任务示例
- **references/web_keycodes.md**: 完整的 KeyboardEvent.code 对照表
