.PHONY: build run deps

bin/proxy: proxy.go
	go build -o bin/proxy proxy.go

build: bin/proxy

run: bin/proxy
	bin/proxy

deps:
	go get github.com/bradfitz/http2
	go get github.com/mreiferson/go-httpclient
