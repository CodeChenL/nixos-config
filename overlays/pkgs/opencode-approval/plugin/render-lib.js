// 宿主注入的 OpenTUI 运行时模块（opencode 2.0.22 的 runtime-plugin-support 机制）。
// 必须使用 opentui:runtime-module:* 虚拟标识：插件自带的 @opentui/solid 副本拿不到
// 宿主 Solid RendererContext，元素创建会报 "No renderer found"。
// 详见 README「TUI 集成」一节；宿主升级导致虚拟模块 id 变化时此文件需同步。
export { createElement, insert, setProp } from "opentui:runtime-module:%40opentui%2Fsolid";
export { createSignal } from "opentui:runtime-module:solid-js";
