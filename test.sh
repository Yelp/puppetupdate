#!/bin/bash

set -eu

bundle install
bundle exec rake spec
