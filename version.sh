#!/bin/sh

set -e

VERSION_NAME=1.0.0
VERSION_TARGET=$1

echo "alter version to $VERSION_NAME"

do_version_readme() {
    
    cat README.md \
    | sed "s/\(git checkout -B latest v\)[[:digit:]][[:digit:].]*/\1$VERSION_NAME/g" \
    | sed "s#\(.*download/k\)\([[:digit:]][[:digit:].]*\)\(/FSPlayer.spec.json\)#\1$VERSION_NAME\3#g" \
    > README.md.new

    mv -f README.md.new README.md
}

do_version_xcode() {
    sed -i "" "s/\([[:space:]]*s.version[[:space:]]*=[[:space:]]*\)\'[[:digit:].]*[[:digit:]]\'/\1\'$VERSION_NAME\'/" FSPlayer.podspec
    pod install --project-directory=examples/ios >/dev/null
    pod install --project-directory=examples/macos >/dev/null
    pod install --project-directory=examples/tvos >/dev/null
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

