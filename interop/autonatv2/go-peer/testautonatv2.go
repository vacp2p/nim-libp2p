package main

import (
	"fmt"
	"log"

	libp2p "github.com/libp2p/go-libp2p"
)

func main() {
	// ctx := context.Background()
	fmt.Println("here")

	// Create a host that listens on TCP port 4040
	h, err := libp2p.New(
		libp2p.EnableAutoNATv2(),
		libp2p.ListenAddrStrings(
			"/ip4/0.0.0.0/tcp/4040", // listen on all interfaces, TCP 4040
			"/ip6/::/tcp/4040",      // IPv6 as well
		),
	)
	if err != nil {
		log.Fatalf("Failed to create host: %v", err)
	}
	defer h.Close()

	fmt.Println(h.ID())
	fmt.Println(h.Addrs())


	fmt.Println("AutoNATv2 client started.")

	// Keep the program running
	select {}
}

