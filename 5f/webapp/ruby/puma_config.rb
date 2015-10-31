directory '/home/isucon/webapp/ruby'
daemonize false
pidfile '/home/isucon/webapp/ruby/puma.pid'
state_path '/tmp/puma.state'
stdout_redirect '/tmp/puma-out.log', '/tmp/puma-err.log', true
threads 0, 32
bind 'unix:///tmp/puma.sock'
