# IPKVM Controller Skill

OpenClaw Skill for remote controlling machines via IPKVM HTTP API.

## 功能特性

- 📸 **屏幕截图**: 获取被控机实时屏幕图像
- 🖱️ **鼠标控制**: 支持绝对坐标 `[0.00, 1.00]` 和相对坐标（像素）模式
- ⌨️ **键盘模拟**: 完整的按键按下/释放控制
- 📝 **智能文本输入**: 自动分段，每30字符后暂停1000ms确保完整输入
- ⏱️ **延时控制**: 确保操作序列正确执行

## 快速开始

### 1. 环境配置

```bash
export IPKVM_URL="http://192.168.2.224:8080"
```

### 2. 使用示例

#### Bash 方式
```bash
# 发送控制指令
./scripts/send_control.sh '{"events":[["text","hello"],["delay",300]]}'

# 获取截图
curl -X GET "${IPKVM_URL}/api/snapshot" -o screen.jpeg
```

#### Python 方式（推荐）
```python
from scripts.ipkvm_client import IPKVMClient

client = IPKVMClient()

# 获取截图
client.screenshot("desktop.jpeg")

# 输入文本（自动分段：每30字符后暂停1000ms）
client.text("This is a long text that will be automatically split into chunks...")

# 组合键 Win+R
client.key_combo("MetaLeft", "KeyR")

# 点击屏幕中心
client.click(0.5, 0.5)
```

### 3. 使用示例JSON

```bash
# 打开浏览器访问百度
curl -X POST "${IPKVM_URL}/api/control"   -H "Content-Type: application/json"   -d @examples/open_browser.json
```

## 文档结构

```
ipkvm/
├── SKILL.md                    # 主技能文档（OpenClaw规范）
├── README.md                   # 本文件
├── scripts/
│   ├── send_control.sh         # Bash快速调用脚本
│   └── ipkvm_client.py         # Python客户端封装（支持自动分段）
├── examples/
│   ├── open_browser.json       # 打开浏览器访问百度
│   ├── open_notepad.json       # 打开记事本
│   ├── mouse_demo.json         # 鼠标操作演示
│   ├── keyboard_shortcuts.json # 组合键演示
│   └── long_text_input.json    # 长文本分段输入演示
└── references/
    └── web_keycodes.md         # 按键代码参考表
```

## 事件类型速查

| 事件 | 格式 | 说明 |
|:---|:---|:---|
| 键盘 | `["keyboard", "KeyA", true]` | 按下A键 |
| 鼠标绝对 | `["mouse_abs", 0, 0.5, 0.5, 0, 0]` | 移动到屏幕中心 |
| 鼠标相对 | `["mouse_rel", 0, 100, 100, 0, 0]` | 右下移100像素 |
| 文本 | `["text", "hello"]` | 输入文本 |
| 延时 | `["delay", 1000]` | 暂停1000毫秒 |

## 重要提示：长文本输入

根据IPKVM文档要求，**文本长度约30字符时需要暂停1000毫秒**确保完整输入。

### 手动分段示例
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

### Python客户端自动分段
```python
# 自动处理：每30字符后添加1000ms暂停
client.text("This is a long text that will be automatically split into chunks...")
```

## 安装到 OpenClaw

```bash
# 复制到 OpenClaw skills 目录
cp -r ipkvm ~/.openclaw/skills/

# 验证安装
openclaw skills list
```

## 依赖

- `curl`: 用于HTTP请求
- `python3` + `requests`: 用于Python客户端（可选）
- `jq`: 用于JSON格式化（可选）

## 许可证

MIT License
