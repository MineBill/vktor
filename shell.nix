# { pkgs ? (import <nixpkgs> {}) }:
# with pkgs;
# mkShell {
#   buildInputs = [
#     # put packages here.
#     glslang # or shaderc
#     vulkan-headers
#     vulkan-loader
#     vulkan-tools
#     vulkan-validation-layers # maybe?
#     just
#     clang
#     glfw-wayland
#     ripgrep
#     # glm and whatnot …
#   ];

#   # # If it doesn’t get picked up through nix magic
#   VULKAN_SDK = "${vulkan-validation-layers}/share/vulkan/explicit_layer.d";
# }

{ pkgs ? import <nixpkgs> { }, lib ? pkgs.lib }:
pkgs.mkShell rec {
    name = "vulkan-env";
    buildInputs = with pkgs; [
            # cargo
            # clang
            # openssl
            # pkgconfig
            # git
            # xorg.libX11
            # xorg.libXcursor
            # xorg.libXrandr
            # xorg.libXi
# alsaLib
# freetype
# expat
            go-task
            clang
            ripgrep
            glfw-wayland
            just

            shaderc
            vulkan-tools
            vulkan-loader
            vulkan-validation-layers
            vulkan-tools-lunarg
            vulkan-extension-layer
    ];
    LD_LIBRARY_PATH = "${lib.makeLibraryPath buildInputs}";
    VK_LAYER_PATH = "${pkgs.vulkan-validation-layers}/share/vulkan/explicit_layer.d";
    XDG_DATA_DIRS = builtins.getEnv "XDG_DATA_DIRS";
    XDG_RUNTIME_DIR = builtins.getEnv "XDG_RUNTIME_DIR";
}
