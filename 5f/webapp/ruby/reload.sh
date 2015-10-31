#!/bin/bash
bundle install --jobs 30
(
  cd ext
  ruby extconf.rb
  make
)
