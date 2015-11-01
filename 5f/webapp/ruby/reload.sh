#!/bin/bash
set -e
bundle install --jobs 30
(
  cd ext
  ruby extconf.rb
  make
)
set +e
kill -USR2 $(cat /home/isucon/webapp/ruby/unicorn.pid)
kill -USR2 $(cat /home/isucon/webapp/ruby/puma.pid)
