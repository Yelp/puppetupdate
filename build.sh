#!/bin/bash

set -eu

if [ -z "${BUILD_NUMBER}" ]; then
    echo "Empty BUILD_NUMBER var"
    exit 1
fi

/usr/bin/mco plugin package --revision "$BUILD_NUMBER"
chmod a+w *.deb
