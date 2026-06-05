# applyDebianPatches: 读取 src 中的 debian/patches/series，自动应用所有补丁
# 用法：在 mkDerivation 中添加 `postPatch = applyDebianPatches;`
{ lib }:

''
  if [ -f debian/patches/series ]; then
    echo "Applying debian patches from debian/patches/series..."
    while IFS= read -r patch; do
      [ -z "$patch" ] && continue
      [[ "$patch" == \#* ]] && continue
      if [ -f "debian/patches/$patch" ]; then
        echo "  Applying: $patch"
        patch -p1 < "debian/patches/$patch"
      else
        echo "  WARNING: patch not found: debian/patches/$patch"
      fi
    done < debian/patches/series
    echo "Done applying debian patches."
  fi
''
