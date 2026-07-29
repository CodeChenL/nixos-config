{ inputs, final, prev }:
let
  # Use unstable nixpkgs for newer llama-cpp version (10063+)
  unstable = import inputs.nixpkgs-unstable {
    system = prev.stdenv.hostPlatform.system;
    config = { allowUnfree = true; };
  };

  # First override to enable all standard backends
  llama-cpp-with-backends = unstable.llama-cpp.override {
    cudaSupport = true;
    vulkanSupport = true;
    openclSupport = true;
    blasSupport = true;
    rpcSupport = true;
  };
in
{
  llama-cpp-full = llama-cpp-with-backends.overrideAttrs (oldAttrs: {
    # Add OpenVINO support (not available as a standard option)
    cmakeFlags = (oldAttrs.cmakeFlags or []) ++ [
      "-DGGML_OPENVINO:BOOL=TRUE"
    ];

    # Add OpenVINO and OpenCL dependencies
    buildInputs = (oldAttrs.buildInputs or []) ++ [
      final.openvino
      final.onetbb
      final.opencl-headers
      final.opencl-clhpp
      final.ocl-icd
    ];

    # Add OpenVINO to nativeBuildInputs for cmake find_package
    nativeBuildInputs = (oldAttrs.nativeBuildInputs or []) ++ [
      final.pkg-config
    ];

    # Set OpenVINO environment variables
    preConfigure = (oldAttrs.preConfigure or "") + ''
      # Help cmake find OpenVINO and TBB
      export CMAKE_PREFIX_PATH="${final.openvino}/runtime/cmake:${final.onetbb.dev}/lib/cmake/TBB''${CMAKE_PREFIX_PATH:+:$CMAKE_PREFIX_PATH}"
    '';

    # Fix postInstall: rpc-server renamed to ggml-rpc-server in newer versions
    postInstall = ''
      mkdir -p $out/include
      cp $src/include/llama.h $out/include/
    ''
    + final.lib.optionalString (final.stdenv.buildPlatform.canExecute final.stdenv.hostPlatform) ''
      installShellCompletion --cmd llama-server --bash <($out/bin/llama-server --completion-bash)
    ''
    + final.lib.optionalString true ''
      if [ -f bin/ggml-rpc-server ]; then
        cp bin/ggml-rpc-server $out/bin/llama-rpc-server
      elif [ -f bin/rpc-server ]; then
        cp bin/rpc-server $out/bin/llama-rpc-server
      fi
    '';

    meta = (oldAttrs.meta or {}) // {
      description = "LLM inference in C/C++ with full backend support (OpenVINO, CUDA, Vulkan, OpenCL, BLAS)";
      platforms = final.lib.platforms.unix;
    };
  });
}
