#!/bin/bash

set -eu

/usr/bin/mco plugin package --iteration "$BUILD_NUMBER"
chmod a+w *.deb
