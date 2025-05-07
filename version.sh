#!/bin/sh

set -e

VERSION_NAME=1.0.1
VERSION_TARGET=$1

echo "alter version to $VERSION_NAME"

do_version_readme() {
    sed -i "" "s#\(.*releases/download/\)\([[:digit:]][[:digit:].]*\)\(/FSPlayer.spec.json\)#\1$VERSION_NAME\3#g" README.md
}

do_version_xcode() {
    sed -i "" "s/\([[:space:]]*MARKETING_VERSION:[[:space:]]\)[[:digit:].]*[[:digit:]]/\1$VERSION_NAME/g" FSPlayer.yml
    ./examples/ios/generate-fsplayer.sh
    ./examples/tvos/generate-fsplayer.sh
    ./examples/macos/generate-fsplayer.sh
}

if [ "$VERSION_TARGET" = "readme" ]; then
    do_version_readme
elif [ "$VERSION_TARGET" = "show" ]; then
    echo $VERSION_NAME
elif [ "$VERSION_TARGET" = "xcode" ]; then
    do_version_xcode
else
    do_version_readme
    do_version_xcode
fi

