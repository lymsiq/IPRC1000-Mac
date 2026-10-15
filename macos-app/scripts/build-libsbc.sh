#!/bin/zsh
set -euo pipefail

root_dir=${0:A:h:h}
archive="$root_dir/Vendor/Source/sbc-2.2.tar.xz"
build_dir=$(mktemp -d /private/tmp/iprc1000-sbc.XXXXXX)
trap 'rm -rf "$build_dir"' EXIT

tar -xf "$archive" -C "$build_dir"
source_dir="$build_dir/sbc-2.2/sbc"
mkdir -p "$build_dir/objects" "$root_dir/Vendor/lib"

sdk=/Library/Developer/CommandLineTools/SDKs/MacOSX15.4.sdk
common_flags=(-O2 -fPIC -DSBC_HIGH_PRECISION -mmacosx-version-min=14.0 -isysroot "$sdk" -I"$source_dir")

clang -c $common_flags \
    "$source_dir/sbc.c" -o "$build_dir/objects/sbc.o"
clang -c $common_flags \
    "$source_dir/sbc_primitives.c" -o "$build_dir/objects/sbc_primitives.o"
ar rcs "$root_dir/Vendor/lib/libsbc.a" \
    "$build_dir/objects/sbc.o" "$build_dir/objects/sbc_primitives.o"
