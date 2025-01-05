#!/bin/sh

set -ex

PREFIX=''

install_dependencies() {
  case "$(uname -s)" in
    Darwin)
      install_dependencies_macos
      PREFIX=$(brew --prefix)
      export PATH="$PREFIX/opt/texinfo/bin:$PATH"
      ;;
    Linux)
      install_dependencies_linux
      PREFIX='/usr'
      ;;
    *)
      echo "Unsupported OS: $(uname -s)"
      exit 1
      ;;
  esac
}

cross_sed() {
  case "$(uname -s)" in
    Darwin)
      sed -i '' "$@"
      ;;
    Linux)
      sed -i "$@"
      ;;
    *)
      echo "Unsupported OS: $(uname -s)"
      exit 1
      ;;
  esac
}

install_dependencies_macos() {
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
    capstone \
    hidapi

  brew install --cask gcc-arm-embedded
}

install_dependencies_linux() {
  wget -qO - 'https://proget.makedeb.org/debian-feeds/prebuilt-mpr.pub' | gpg --dearmor | sudo tee /usr/share/keyrings/prebuilt-mpr-archive-keyring.gpg 1> /dev/null
  echo "deb [arch=all,$(dpkg --print-architecture) signed-by=/usr/share/keyrings/prebuilt-mpr-archive-keyring.gpg] https://proget.makedeb.org prebuilt-mpr $(lsb_release -cs)" | sudo tee /etc/apt/sources.list.d/prebuilt-mpr.list
  sudo apt-get update


  sudo apt-get install -y \
    git \
    cmake \
    gcc \
    automake \
    autoconf \
    texinfo \
    libtool \
    libftdi-dev \
    libusb-1.0-0-dev \
    libhidapi-dev \
    just \
    wget \
    pkg-config \
    libcapstone-dev

  sudo apt-get install -y gcc-arm-none-eabi
}

download_libraries() {
  for library in pico-sdk pico-examples pico-extras pico-playground debugprobe picotool openocd; do
    [ ! -d "$library" ] && git clone "https://github.com/raspberrypi/$library"
    cd "$library"
    git pull
    git submodule update --init
    cd ..
  done
}

build_images() {
  mkdir -p images

  cd pico-sdk
  cross_sed 's/#define PICO_FLASH_SPI_CLKDIV 2/#define PICO_FLASH_SPI_CLKDIV 4/' "src/boards/include/boards/waveshare_rp2040_zero.h"
  cd ..

  cd picotool
  mkdir -p build
  cd build
  cmake ..
  make
  cd ../..
  cp picotool/build/picotool "$HOME/.local/bin/picotool"

  cd debugprobe
  mkdir -p build
  cd build
  cmake -DDEBUG_ON_PICO=ON ..
  make
  cd ../..
  cp debugprobe/build/debugprobe_on_pico.uf2 images/debugprobe_on_pico.uf2

  cd pico-examples
  mkdir -p build
  cd build
  cmake ..
  cd flash
  make
  cd ../../..
  cp pico-examples/build/flash/nuke/flash_nuke.uf2 images/flash_nuke.uf2

  cd openocd
    ./bootstrap
  CAPSTONE_CFLAGS="-I$PREFIX/include/capstone" ./configure --enable-picoprobe --enable-cmsis-dap --disable-presto --disable-werror --disable-openjtag
  make -j4
  sudo make install
  cd ..

  wget https://micropython.org/resources/firmware/RPI_PICO-20231005-v1.21.0.uf2 -O images/RPI_PICO-20231005-v1.21.0.uf2

  wget https://github.com/kaluma-project/kaluma/releases/download/1.0.0/kaluma-rp2-pico-1.0.0.uf2 -O images/kaluma-rp2-pico-1.0.0.uf2
}

set_sdk_path() {
  cross_sed '/export PICO_SDK_PATH=/d' "$HOME/.zshrc"
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
cp "$HOME/.pico/pico-extras/external/pico_extras_import.cmake" ./

cat > CMakeLists.txt <<CMAKE
cmake_minimum_required(VERSION 3.27)

include(pico_sdk_import.cmake)
# include(pico_extras_import.cmake)

set(CMAKE_EXPORT_COMPILE_COMMANDS ON)
set(CMAKE_C_STANDARD 23)
set(CMAKE_CXX_STANDARD 17)

project(${PROJECT_NAME} VERSION 1.0.0)

pico_sdk_init()

add_executable(${PROJECT_NAME} src/main.c)

target_link_libraries(${PROJECT_NAME} PRIVATE pico_stdlib)

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

clean:
  @rm -rf build

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

cat > .vscode/settings.json <<'JSON'
{
  "cmake.configureOnOpen": true,
  "C_Cpp.default.compileCommands": "${workspaceFolder}/build/compile_commands.json",
  "C_Cpp.default.configurationProvider": "ms-vscode.cmake-tools"
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
