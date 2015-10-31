#!/bin/bash
set -e
bundle install --jobs 30
(
  cd ext
  ruby extconf.rb
  make
)

