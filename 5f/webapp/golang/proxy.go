package main

import (
	"crypto/tls"
	"errors"
	"github.com/bradfitz/http2"
	httpclient "github.com/mreiferson/go-httpclient"
	"io/ioutil"
	"log"
	"net/http"
	"runtime"
	"sync"
	"time"
)

const (
	BASE_URL = "https://api.five-final.isucon.net:8443/"
)

var (
	ENDPOINTS = map[string]string{
		"/tokens":        "api.five-final.isucon.net:8443",
		"/attacked_list": "api.five-final.isucon.net:8443",
	}
)

var ValidReqHeaders = map[string]bool{
	"Accept":         true,
	"Accept-Charset": true,
	// images (aside from xml/svg), don't generally benefit (generally) from
	// compression
	"Accept-Encoding":          false,
	"Accept-Language":          true,
	"Cache-Control":            true,
	"If-None-Match":            true,
	"If-Modified-Since":        true,
	"X-Forwarded-For":          true,
	"X-Perfect-Security-Token": true,
}

var ValidRespHeaders = map[string]bool{
	// Do not offer to accept range requests
	"Accept-Ranges":     false,
	"Cache-Control":     true,
	"Content-Encoding":  true,
	"Content-Type":      true,
	"Transfer-Encoding": true,
	"Expires":           true,
	"Last-Modified":     true,
	"ETag":              true,
	// override in response with either nothing, or ServerNameVer
	"Server": false,
}

var mutex *sync.Mutex

func main() {
	runtime.GOMAXPROCS(runtime.NumCPU())
	mutex = new(sync.Mutex)
	http2.VerboseLogs = true

	http.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		_, res := getResponse(r)

		if res == nil {
			log.Printf("!!! Request Failed : Can't success request !!!")
			http.Error(w, "だめです", 500)
			return
		}
		defer res.Body.Close()

		bytes, err := ioutil.ReadAll(res.Body)
		if err != nil {
			log.Printf("!!! Request Failed : Can't read body !!!")
			http.Error(w, "だめです", 500)
			return
		}

		for k, v := range res.Header {
			for _, vv := range v {
				w.Header().Add(k, vv)
			}
		}

		w.Header().Set("Content-Type", "application/json")

		w.WriteHeader(res.StatusCode)
		w.Write(bytes)

		log.Printf("%s : %s", res.Status, r.URL.String())
	})

	http.ListenAndServe(":9293", nil)
}

func getResponse(req *http.Request) (*http.Request, *http.Response) {
	endpoint := ENDPOINTS[req.URL.Path]
	req.URL.Host = endpoint
	req.URL.Scheme = "https"
	log.Printf("Request: %s", req.URL.String())
	log.Printf("Security Token: %s", req.Header.Get("X-Perfect-Security-Token"))

	nreq, err := http.NewRequest("GET", req.URL.String(), nil)
	if err != nil {
		log.Printf("%s", err)
		return nreq, nil
	}

	copyHeaders(&nreq.Header, &req.Header)
	nreq.Header.Set("User-Agent", "isucon-proxy")
	nreq.Header.Set("Via", "isucon-proxy")

	client := getClinet(req.Header.Get("X-Perfect-Security-Token"))
	resp, err := client.Do(nreq)
	if err != nil {
		log.Printf("Request Error: %s", err)
		return nreq, nil
	}

	return nreq, resp
}

func copyHeaders(dst, src *http.Header) {
	for k, vv := range *src {
		for _, v := range vv {
			dst.Add(k, v)
		}
	}
}

var clients = map[string]*http.Client{}
var client *http.Client

func getClinet(token string) *http.Client {
	mutex.Lock()
	defer mutex.Unlock()

	if client != nil {
		return client
	}

	cli, ok := clients[token]
	if ok {
		return cli
	}

	tr := &httpclient.Transport{
		MaxIdleConnsPerHost: 10,
		ConnectTimeout:      2 * time.Second,
		DisableKeepAlives:   false,
		TLSClientConfig: &tls.Config{
			InsecureSkipVerify: true,
		},
	}

	go func() {
		for {
			time.Sleep(5 * time.Second)
			tr.CloseIdleConnections()
		}
	}()

	h2tr := &http2.Transport{
		Fallback:        tr,
		InsecureTLSDial: true,
	}

	go func() {
		for {
			time.Sleep(5 * time.Second)
			h2tr.CloseIdleConnections()
		}
	}()

	client = &http.Client{Transport: tr}
	client.CheckRedirect = func(req *http.Request, via []*http.Request) error {
		if len(via) >= 8 {
			return errors.New("Too many redirects")
		}
		return nil
	}

	clients[token] = client

	return client
}
