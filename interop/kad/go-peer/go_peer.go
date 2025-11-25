package main

import (
    "context"
    "crypto/rand"
    "fmt"
    "io/ioutil"
    "log"
    "os"

    libp2p "github.com/libp2p/go-libp2p"
    crypto "github.com/libp2p/go-libp2p/core/crypto"
    peer "github.com/libp2p/go-libp2p/core/peer"
    dht "github.com/libp2p/go-libp2p-kad-dht"
    rhost "github.com/libp2p/go-libp2p/p2p/host/routed"
)

const (
    privKeyFile = "peer.key"
    peerIDFile  = "peer.id"
)

type MyValidator struct{}

// Runs when a PUT_VALUE arrives
func (v *MyValidator) Validate(key string, value []byte) error {
    fmt.Println("=== RECEIVED PUT_VALUE ===")
    fmt.Println("Key:", key)
    fmt.Println("Value:", string(value))

    // Write the success file
    ioutil.WriteFile("successful", []byte("ok\n"), 0644)

    return nil // accept record
}

func (v *MyValidator) Select(best [][]byte) (int, error) {
    // Always select first (not important here)
    return 0, nil
}

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

        // Load peer ID
        pidData, err := ioutil.ReadFile(peerIDFile)
        if err != nil {
            return nil, "", fmt.Errorf("failed to read peer ID: %w", err)
        }
        pid, err := peer.Decode(string(pidData))
        if err != nil {
            return nil, "", fmt.Errorf("peer ID decode error: %w", err)
        }
        return priv, pid, nil
    }

    // Create new identity
    priv, pub, err := crypto.GenerateEd25519Key(rand.Reader)
    if err != nil {
        return nil, "", err
    }

    pid, err := peer.IDFromPublicKey(pub)
    if err != nil {
        return nil, "", err
    }

    // Save private key
    privBytes, _ := crypto.MarshalPrivateKey(priv)
    ioutil.WriteFile(privKeyFile, privBytes, 0600)
    ioutil.WriteFile(peerIDFile, []byte(pid.String()), 0644)

    return priv, pid, nil
}

func main() {
    ctx := context.Background()

    priv, pid, err := loadOrCreateIdentity()
    if err != nil {
        log.Fatal(err)
    }

    // Create main libp2p host
    host, err := libp2p.New(
        libp2p.Identity(priv),
        libp2p.ListenAddrStrings("/ip4/0.0.0.0/tcp/4040"),
    )
    if err != nil {
        log.Fatal(err)
    }

    // Create Kademlia DHT
	kad, err := dht.New(ctx, host, dht.Mode(dht.ModeServer), dht.ProtocolPrefix("/ipfs"))
	if err != nil { log.Fatal(err) }
	routed := rhost.Wrap(host, kad)
	fmt.Println("Peer ID:", pid)
	fmt.Println("Listen addresses:", routed.Addrs())
	fmt.Println("Go Kademlia DHT node started")

	// Keep running

	select {}
}

