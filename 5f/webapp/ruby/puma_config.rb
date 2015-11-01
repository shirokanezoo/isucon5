directory '/home/isucon/webapp/ruby'
daemonize false
pidfile '/home/isucon/webapp/ruby/puma.pid'
state_path '/tmp/puma.state'
stdout_redirect '/tmp/puma-out.log', '/tmp/puma-err.log', true
bind 'unix:///tmp/puma.sock'

workers 3
threads 0, 12
preload_app!

on_worker_boot do
  if defined?(Redis) && Redis.current.connected?
    Redis.current.client.reconnect
  end
end
