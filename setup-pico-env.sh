#!/bin/sh

set -ex

function install_dependencies {
  case "$(uname -s)" in
    Darwin)
      install_dependencies_macos
      ;;
    Linux)
      install_dependencies_linux
      ;;
    *)
      echo "Unsupported OS: $(uname -s)"
      exit 1
      ;;
  esac
}

function install_dependencies_macos {
  brew install \
    git \
    cmake \
    gcc \
    automake \
    autoconf \
    texinfo \
    libtool \
    libftdi \
    libusb \
    libusb-compat \
    just \
    wget \
    pkg-config \
    capstone

  brew install --cask gcc-arm-embedded
}

function download_libraries {
  for library in pico-sdk pico-examples pico-extras pico-playground debugprobe picotool openocd; do
    [ ! -d "$library" ] && git clone "https://github.com/raspberrypi/$library"
    cd "$library"
    git pull
    git submodule update --init
    cd ..
  done
}

function build_images {
  mkdir -p images

  cd debugprobe
  mkdir -p build
  cd build
  cmake ..
  make
  cd ../..
  cp debugprobe/build/debugprobe.uf2 images/debugprobe.uf2

  cd picotool
  mkdir -p build
  cd build
  cmake ..
  make
  cd ../..
  cp picotool/build/picotool "$HOME/.local/bin/picotool"

  cd pico-examples
  mkdir -p build
  cd build
  cmake ..
  cd flash
  make
  cd ../../..
  cp pico-examples/build/flash/nuke/flash_nuke.uf2 images/flash_nuke.uf2

  cd openocd
  export PATH="$(brew --prefix)/opt/texinfo/bin:$PATH"
  ./bootstrap
  CAPSTONE_CFLAGS="-I$(brew --prefix)/include" ./configure --enable-picoprobe --disable-presto --disable-werror --disable-openjtag
  make -j4
  make install
  cd ..

  wget https://micropython.org/resources/firmware/RPI_PICO-20231005-v1.21.0.uf2 -O images/RPI_PICO-20231005-v1.21.0.uf2

  wget https://github.com/kaluma-project/kaluma/releases/download/1.0.0/kaluma-rp2-pico-1.0.0.uf2 -O images/kaluma-rp2-pico-1.0.0.uf2
}

function set_sdk_path {
  sed -i '' '/export PICO_SDK_PATH=/d' "$HOME/.zshrc"
  echo "export PICO_SDK_PATH=\"$HOME/.pico/pico-sdk\"" >> "$HOME/.zshrc"
}

install_dependencies

mkdir -p "$HOME/.pico"
cd "$HOME/.pico"

download_libraries

export PICO_SDK_PATH="$HOME/.pico/pico-sdk"

build_images
set_sdk_path

cat > "$HOME/.local/bin/open-pico-images" <<'EOF'
#!/bin/sh

set -ex

open "$HOME/.pico/images"
EOF
chmod +x "$HOME/.local/bin/open-pico-images"

cat > "$HOME/.local/bin/create-pico-project" <<'EOF'
#!/bin/sh

set -e

PROJECT_NAME=$1

if [ -z "$PROJECT_NAME" ]; then
  echo "\033[0;32mUsage:\033[0m create-pico-project \033[0;33m<project-name>\033[0m"
  exit 1
fi

if [ -d "$PROJECT_NAME" ]; then
  echo "\033[0;31mError:\033[0m Directory \033[0;33m$PROJECT_NAME\033[0m already exists"
  exit 1
fi

mkdir "$PROJECT_NAME"
cd "$PROJECT_NAME"

cp "$HOME/.pico/pico-sdk/external/pico_sdk_import.cmake" ./
cp "$HOME/.pico/pico-sdk/external/pico_extras_import.cmake" ./

cat > CMakeLists.txt <<CMAKE
cmake_minimum_required(VERSION 3.12)

include(pico_sdk_import.cmake)
# include(pico_extras_import.cmake)

set(CMAKE_EXPORT_COMPILE_COMMANDS ON)
set(CMAKE_C_STANDARD 11)
set(CMAKE_CXX_STANDARD 17)

project(${PROJECT_NAME} VERSION 1.0.0)

add_executable(${PROJECT_NAME} src/main.c)

target_link_libraries(${PROJECT_NAME} PRIVATE pico_stdlib)

pico_sdk_init()

pico_enable_stdio_usb(${PROJECT_NAME} 1)
pico_enable_stdio_uart(${PROJECT_NAME} 1)

pico_add_extra_outputs(${PROJECT_NAME})

CMAKE

mkdir src
cat > src/main.c <<C
#include <stdio.h>
#include "pico/stdlib.h"

int main() {
  stdio_init_all();

  gpio_init(PICO_DEFAULT_LED_PIN);
  gpio_set_dir(PICO_DEFAULT_LED_PIN, GPIO_OUT);

  while (true) {
    printf("Hello, world! - ${PROJECT_NAME}\n");
    gpio_put(PICO_DEFAULT_LED_PIN, true);
    sleep_ms(1000);
    gpio_put(PICO_DEFAULT_LED_PIN, false);
    sleep_ms(1000);
  }
}

C

cat > justfile <<JUST
set dotenv-load

default: build upload

build:
  @mkdir -p build
  @cd build && cmake ..
  @cd build && make

upload:
  openocd -f interface/cmsis-dap.cfg -c "adapter speed 5000" -f target/rp2040.cfg -c "program build/$PROJECT_NAME.elf verify reset exit"

JUST

cat > .env <<'ENV'
export PICO_SDK_PATH="$HOME/.pico/pico-sdk"
ENV

cat > .gitignore <<GITIGNORE
/build
GITIGNORE

mkdir .vscode

cat > .vscode/c_cpp_properties.json <<'JSON'
{
  "configurations": [
    {
      "name": "Pico on MacOS",
      "includePath": [
        "${workspaceFolder}/**"
      ],
      "defines": [],
      "macFrameworkPath": [
        "/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk/System/Library/Frameworks"
      ],
      "compilerPath": "/usr/bin/clang",
      "cStandard": "c11",
      "cppStandard": "c++17",
      "intelliSenseMode": "macos-clang-arm64",
      "compileCommands": "${workspaceFolder}/build/compile_commands.json"
    }
  ],
  "version": 4
}
JSON

cat > .vscode/settings.json <<'JSON'
{
  "cmake.configureOnOpen": true
}
JSON

cat > .vscode/launch.json <<'JSON'
{
  "version": "0.2.0",
  "configurations": [
    {
      "name": "Debug Pico",
      "type": "cortex-debug",
      "device": "RP2040",
      "gdbPath": "arm-none-eabi-gdb",
      "cwd": "${workspaceRoot}",
      "executable": "${command:cmake.launchTargetPath}",
      "request": "launch",
      "servertype": "openocd",
      "configFiles": [
        "/interface/cmsis-dap.cfg",
        "/target/rp2040.cfg"
      ],
      "openOCDLaunchCommands": [
        "adapter speed 5000",
      ],
      "svdFile": "${env:PICO_SDK_PATH}/src/rp2040/hardware_regs/rp2040.svd",
      "runToEntryPoint": "main",
      "postRestartCommands": [
        "break main",
        "continue"
      ]
    }
  ]
}
JSON

git init

git add .

git commit -m "Initial commit"

just build

EOF
chmod +x "$HOME/.local/bin/create-pico-project"

code --install-extension marus25.cortex-debug --force
code --install-extension ms-vscode.cmake-tools --force
code --install-extension ms-vscode.cpptools --force
code --install-extension skellock.just --force
code --install-extension ms-vscode.vscode-serial-monitor --force
