#!/usr/bin/env python3
"""
IPKVM Python客户端封装
提供友好的API用于远程控制被控机

环境变量:
    IPKVM_URL: IPKVM设备URL (默认: http://192.168.2.224:8080)

示例:
    from ipkvm_client import IPKVMClient

    client = IPKVMClient()

    # 获取截图
    client.screenshot("desktop.jpeg")

    # 输入文本（自动分段，每30字符后暂停1000ms）
    client.text("This is a long text that will be automatically split into chunks...")

    # 组合键 Win+R
    client.key_combo("MetaLeft", "KeyR")

    # 点击屏幕中心
    client.click(0.5, 0.5)
"""

import os
import time
import requests
from typing import List, Union, Optional
from dataclasses import dataclass


@dataclass
class Point:
    """坐标点"""
    x: float
    y: float


class IPKVMClient:
    """IPKVM HTTP API 客户端"""

    # 常用按键常量
    KEY_WIN = "MetaLeft"
    KEY_CTRL = "ControlLeft"
    KEY_ALT = "AltLeft"
    KEY_SHIFT = "ShiftLeft"
    KEY_ENTER = "Enter"
    KEY_ESC = "Escape"
    KEY_TAB = "Tab"
    KEY_SPACE = "Space"

    # 文本分段配置：每30字符后暂停1000ms
    TEXT_CHUNK_SIZE = 30
    TEXT_DELAY_MS = 1000

    def __init__(self, url: Optional[str] = None):
        """
        初始化客户端

        Args:
            url: IPKVM设备URL，默认从环境变量 IPKVM_URL 读取
        """
        self.url = url or os.getenv('IPKVM_URL', 'http://192.168.2.224:8080')
        self.session = requests.Session()

    def _request(self, method: str, endpoint: str, **kwargs) -> dict:
        """发送HTTP请求"""
        url = f"{self.url}{endpoint}"
        response = self.session.request(method, url, timeout=30, **kwargs)
        response.raise_for_status()
        return response.json() if response.content else {}

    def screenshot(self, save_path: Optional[str] = None) -> bytes:
        """
        获取屏幕截图

        Args:
            save_path: 保存路径，为None则返回二进制数据

        Returns:
            JPEG图像二进制数据
        """
        url = f"{self.url}/api/snapshot"
        response = self.session.get(url, timeout=10)
        response.raise_for_status()

        data = response.content
        if save_path:
            with open(save_path, 'wb') as f:
                f.write(data)
            print(f"截图已保存: {save_path}")
        return data

    def control(self, events: List[List[Union[str, int, float, bool]]]) -> dict:
        """
        发送控制指令序列

        Args:
            events: 事件列表，每个事件是一个数组

        Returns:
            API响应JSON
        """
        return self._request('POST', '/api/control', json={"events": events})

    def delay(self, milliseconds: int) -> dict:
        """暂停指定毫秒"""
        return self.control([["delay", milliseconds]])

    def text(self, content: str, auto_split: bool = True) -> dict:
        """
        输入文本

        根据文档要求，文本长度约30字符时需要暂停1000毫秒。
        默认自动分段输入，每30字符后自动添加1000ms暂停。

        Args:
            content: 要输入的文本（ASCII字符）
            auto_split: 是否自动分段（默认True）

        Returns:
            API响应JSON
        """
        if not auto_split or len(content) <= self.TEXT_CHUNK_SIZE:
            # 短文本直接发送，并添加适当延时
            delay = self.TEXT_DELAY_MS if len(content) >= 20 else 300
            return self.control([
                ["text", content],
                ["delay", delay]
            ])

        # 长文本自动分段：每30字符后暂停1000ms
        events = []
        for i in range(0, len(content), self.TEXT_CHUNK_SIZE):
            chunk = content[i:i+self.TEXT_CHUNK_SIZE]
            events.append(["text", chunk])
            events.append(["delay", self.TEXT_DELAY_MS])

        return self.control(events)

    def key(self, key_code: str, pressed: bool = True) -> dict:
        """
        发送单个按键事件

        Args:
            key_code: 按键标识符，如 "MetaLeft", "KeyA"
            pressed: True=按下，False=释放
        """
        return self.control([["keyboard", key_code, pressed]])

    def key_combo(self, *keys: str, press_delay: int = 50, post_delay: int = 100) -> dict:
        """
        发送组合键（自动处理按下/释放顺序）

        Args:
            *keys: 按键序列，如 "MetaLeft", "KeyR"
            press_delay: 按键间隔（毫秒）
            post_delay: 释放后的延时（毫秒）
        """
        events = []

        # 依次按下
        for key in keys:
            events.append(["keyboard", key, True])
            if press_delay > 0:
                events.append(["delay", press_delay])

        # 逆序释放
        for key in reversed(keys):
            events.append(["keyboard", key, False])
            if press_delay > 0:
                events.append(["delay", press_delay])

        if post_delay > 0:
            events.append(["delay", post_delay])

        return self.control(events)

    def mouse_abs(self, x: float, y: float, buttons: int = 0, 
                  wheel_y: int = 0, wheel_x: int = 0) -> dict:
        """
        绝对坐标鼠标操作

        Args:
            x: 绝对坐标X [0.00, 1.00]
            y: 绝对坐标Y [0.00, 1.00]
            buttons: 按键状态（0=无，1=左键，2=右键，4=中键）
            wheel_y: 垂直滚轮 [-20, 20]，正值向下
            wheel_x: 水平滚轮 [-20, 20]，正值向右
        """
        return self.control([["mouse_abs", buttons, x, y, wheel_y, wheel_x]])

    def mouse_rel(self, dx: int, dy: int, buttons: int = 0,
                  wheel_y: int = 0, wheel_x: int = 0) -> dict:
        """
        相对坐标鼠标操作

        Args:
            dx: X轴相对位移（像素），正值向右
            dy: Y轴相对位移（像素），正值向下
            buttons: 按键状态
            wheel_y: 垂直滚轮 [-20, 20]
            wheel_x: 水平滚轮 [-20, 20]
        """
        return self.control([["mouse_rel", buttons, dx, dy, wheel_y, wheel_x]])

    def click(self, x: float, y: float, button: str = "left", 
              absolute: bool = True, post_delay: int = 200) -> dict:
        """
        在指定位置点击鼠标

        Args:
            x: X坐标（绝对0-1 或 相对像素）
            y: Y坐标（绝对0-1 或 相对像素）
            button: 按键类型 ("left", "right", "middle")
            absolute: 是否使用绝对坐标
            post_delay: 点击后的延时
        """
        button_map = {"left": 1, "right": 2, "middle": 4}
        btn_code = button_map.get(button, 1)

        event_type = "mouse_abs" if absolute else "mouse_rel"

        events = [
            [event_type, btn_code, x, y, 0, 0],   # 按下
            ["delay", 100],
            [event_type, 0, x, y, 0, 0]            # 释放
        ]

        if post_delay > 0:
            events.append(["delay", post_delay])

        return self.control(events)

    def double_click(self, x: float, y: float, absolute: bool = True) -> dict:
        """双击指定位置"""
        self.click(x, y, absolute=absolute, post_delay=50)
        time.sleep(0.05)
        return self.click(x, y, absolute=absolute)

    def scroll(self, dy: int = 0, dx: int = 0, at_point: Optional[Point] = None) -> dict:
        """
        滚动鼠标滚轮

        Args:
            dy: 垂直滚动量 [-20, 20]，正值向下
            dx: 水平滚动量 [-20, 20]，正值向右
            at_point: 滚动前移动到的位置（绝对坐标）
        """
        events = []

        if at_point:
            events.append(["mouse_abs", 0, at_point.x, at_point.y, 0, 0])
            events.append(["delay", 50])

        events.append(["mouse_abs", 0, 0, 0, dy, dx])

        return self.control(events)

    def run_command(self, command: str, wait: int = 500) -> dict:
        """
        通过 Win+R 运行命令

        Args:
            command: 要运行的命令
            wait: 打开运行窗口后的等待时间（毫秒）
        """
        events = [
            ["keyboard", "MetaLeft", True],
            ["keyboard", "KeyR", True],
            ["delay", 50],
            ["keyboard", "KeyR", False],
            ["keyboard", "MetaLeft", False],
            ["delay", wait],
            ["text", command],
            ["delay", 1000],  # 命令文本后暂停1000ms
            ["keyboard", "Enter", True],
            ["keyboard", "Enter", False]
        ]
        return self.control(events)


# 便捷函数
def quick_text(text: str, url: Optional[str] = None, auto_split: bool = True) -> dict:
    """快速输入文本（自动分段）"""
    client = IPKVMClient(url=url)
    return client.text(text, auto_split=auto_split)


def quick_screenshot(save_path: str = "screen.jpeg", url: Optional[str] = None) -> bytes:
    """快速截图"""
    client = IPKVMClient(url=url)
    return client.screenshot(save_path)


if __name__ == "__main__":
    import sys

    client = IPKVMClient()

    if len(sys.argv) < 2:
        print("IPKVM Client - 远程控制工具")
        print()
        print("用法: python ipkvm_client.py <command> [args]")
        print()
        print("命令:")
        print("  screenshot [path]       - 获取截图 (默认: screen.jpeg)")
        print("  text <content>          - 输入文本（自动分段）")
        print("  run <command>           - 通过Win+R运行命令")
        print("  click <x> <y>           - 点击位置 (0-1绝对坐标)")
        print("  key <key_code>          - 发送单个按键")
        print("  combo <key1> <key2>...  - 发送组合键")
        print()
        print("环境变量:")
        print("  IPKVM_URL - IPKVM设备URL (默认: http://192.168.2.224:8080)")
        print()
        print("示例:")
        print('  python ipkvm_client.py text "Hello World"')
        print('  python ipkvm_client.py run notepad')
        print('  python ipkvm_client.py click 0.5 0.5')
        print('  python ipkvm_client.py combo MetaLeft KeyR')
        sys.exit(1)

    cmd = sys.argv[1]

    if cmd == "screenshot":
        path = sys.argv[2] if len(sys.argv) > 2 else "screen.jpeg"
        client.screenshot(path)

    elif cmd == "text":
        if len(sys.argv) < 3:
            print("错误: 需要提供文本内容")
            sys.exit(1)
        content = sys.argv[2]
        result = client.text(content)
        print(f"已输入 {len(content)} 字符（自动分段）")
        print(f"响应: {result}")

    elif cmd == "run":
        if len(sys.argv) < 3:
            print("错误: 需要提供命令")
            sys.exit(1)
        result = client.run_command(sys.argv[2])
        print(f"响应: {result}")

    elif cmd == "click":
        if len(sys.argv) < 4:
            print("错误: 需要提供 x y 坐标")
            sys.exit(1)
        x, y = float(sys.argv[2]), float(sys.argv[3])
        result = client.click(x, y)
        print(f"响应: {result}")

    elif cmd == "key":
        if len(sys.argv) < 3:
            print("错误: 需要提供按键代码")
            sys.exit(1)
        result = client.key(sys.argv[2])
        print(f"响应: {result}")

    elif cmd == "combo":
        if len(sys.argv) < 3:
            print("错误: 需要提供至少一个按键")
            sys.exit(1)
        keys = sys.argv[2:]
        result = client.key_combo(*keys)
        print(f"组合键 {'+'.join(keys)} 已发送")
        print(f"响应: {result}")

    else:
        print(f"未知命令: {cmd}")
        sys.exit(1)
