#!/bin/sh
set -eu

developer_dir="$(xcode-select -p)"

if [ "$developer_dir" = "/Library/Developer/CommandLineTools" ]; then
    frameworks="$developer_dir/Library/Developer/Frameworks"
    libraries="$developer_dir/Library/Developer/usr/lib"
    exec swift test \
        -Xswiftc -F -Xswiftc "$frameworks" \
        -Xlinker "-F$frameworks" \
        -Xlinker -rpath -Xlinker "$frameworks" \
        -Xlinker -rpath -Xlinker "$libraries"
fi

exec swift test
