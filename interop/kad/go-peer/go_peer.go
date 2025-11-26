package main

import (
    "context"
    "crypto/rand"
    "fmt"
    "io/ioutil"
    "log"
    "os"

    "github.com/libp2p/go-libp2p"
    dht "github.com/libp2p/go-libp2p-kad-dht"
	"github.com/libp2p/go-libp2p/core/host"
	"github.com/libp2p/go-libp2p/core/routing"
    "github.com/libp2p/go-libp2p/core/crypto"
    "github.com/libp2p/go-libp2p/core/peer"
	log2 "github.com/ipfs/go-log/v2"
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

type myValidator struct {}

func (v myValidator) Validate(key string, value []byte) error {
	return nil
}

func (v myValidator) Select(key string, values [][]byte) (int, error) {
	if len(values) == 0 {
		return -1, fmt.Errorf("no values provided")
	}
	return 0, nil
}

func main() {
	_ = log2.SetLogLevel("*", "debug")
    ctx := context.Background()

    priv, pid, err := loadOrCreateIdentity()
    if err != nil {
        log.Fatal(err)
    }

	var idht *dht.IpfsDHT

    // Create main libp2p host
    h, err := libp2p.New(
        libp2p.Identity(priv),
        libp2p.ListenAddrStrings("/ip4/0.0.0.0/tcp/4040"),
		libp2p.Routing(func(h host.Host) (routing.PeerRouting, error) {
			dhtOpts := []dht.Option{
				dht.Mode(dht.ModeServer),
				dht.ProtocolPrefix("/test"),
				dht.Validator(myValidator{}),
			}
			idht, err = dht.New(ctx, h, dhtOpts...)
			return idht, err
		}),
    )
    if err != nil {
        log.Fatal(err)
    }

	fmt.Println("Peer ID:", pid)
	fmt.Println("Listen addresses:", h.Addrs())
	fmt.Println("Go Kademlia DHT node started")

	// Keep running

	select {}
}

