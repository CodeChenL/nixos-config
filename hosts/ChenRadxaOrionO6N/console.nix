{ ... }:

{
  # Orion O6N 的显示控制器更适合走 KMS/DRM 用户态控制台，优先使用
  # kmscon 代替传统 framebuffer VT / autovt。
  services.kmscon = {
    enable = true;
    hwRender = true;
  };
}
