package main

import (
	"crypto/rand"
	"fmt"
	"io/ioutil"
	"log"
	"os"

	libp2p "github.com/libp2p/go-libp2p"
	crypto "github.com/libp2p/go-libp2p/core/crypto"
	peer "github.com/libp2p/go-libp2p/core/peer"
)

const (
	privKeyFile = "peer.key"
	peerIDFile  = "peer.id"
)

func loadOrCreateIdentity() (crypto.PrivKey, peer.ID, error) {
	if _, err := os.Stat(privKeyFile); err == nil {
		// Load private key
		data, err := ioutil.ReadFile(privKeyFile)
		if err != nil {
			return nil, "", fmt.Errorf("failed to read private key: %w", err)
		}
		priv, err := crypto.UnmarshalPrivateKey(data)
		if err != nil {
			return nil, "", fmt.Errorf("failed to unmarshal private key: %w", err)
		}

		// Load peer ID as string
		peerData, err := ioutil.ReadFile(peerIDFile)
		if err != nil {
			return nil, "", fmt.Errorf("failed to read peer ID: %w", err)
		}
		pid, err := peer.Decode(string(peerData))
		if err != nil {
			return nil, "", fmt.Errorf("failed to decode peer ID: %w", err)
		}

		return priv, pid, nil
	}

	// Create new keypair
	priv, pub, err := crypto.GenerateEd25519Key(rand.Reader)
	if err != nil {
		return nil, "", fmt.Errorf("failed to generate keypair: %w", err)
	}
	pid, err := peer.IDFromPublicKey(pub)
	if err != nil {
		return nil, "", fmt.Errorf("failed to derive peer ID: %w", err)
	}

	// Save private key
	privBytes, err := crypto.MarshalPrivateKey(priv)
	if err != nil {
		return nil, "", fmt.Errorf("failed to marshal private key: %w", err)
	}
	if err := ioutil.WriteFile(privKeyFile, privBytes, 0600); err != nil {
		return nil, "", fmt.Errorf("failed to write private key: %w", err)
	}

	// Save peer ID in canonical string form
	if err := ioutil.WriteFile(peerIDFile, []byte(pid.String()), 0644); err != nil {
		return nil, "", fmt.Errorf("failed to write peer ID: %w", err)
	}

	return priv, pid, nil
}

func main() {
	priv, pid, err := loadOrCreateIdentity()
	if err != nil {
		log.Fatalf("Identity setup failed: %v", err)
	}

	h, err := libp2p.New(
		libp2p.Identity(priv),
		libp2p.EnableAutoNATv2(),
		libp2p.ListenAddrStrings(
			"/ip4/0.0.0.0/tcp/4040",
			"/ip6/::/tcp/4040",
		),
	)
	if err != nil {
		log.Fatalf("Failed to create host: %v", err)
	}
	defer h.Close()

	fmt.Println("Peer ID:", pid.String())
	fmt.Println("Listen addresses:", h.Addrs())
	fmt.Println("AutoNATv2 client started.")

	select {}
}

