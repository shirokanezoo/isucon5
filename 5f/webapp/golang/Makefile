.PHONY: build run

bin/proxy: proxy.go
	go build -o bin/proxy proxy.go

build: bin/proxy

run: bin/proxy
	bin/proxy
