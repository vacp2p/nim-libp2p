package main

import (
	"context"
	"crypto/rand"
	"fmt"
	"io/ioutil"
	"log"
	"log/slog"
	"os"
	"time"

	libp2p "github.com/libp2p/go-libp2p"
	pubsub "github.com/libp2p/go-libp2p-pubsub"
	"github.com/libp2p/go-libp2p-pubsub/partialmessages"
	pb "github.com/libp2p/go-libp2p-pubsub/pb"
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

type MyPartsMetadata struct {
	metadata []byte
}

func (m MyPartsMetadata) Encode() []byte {
	return m.metadata
}

func (m MyPartsMetadata) Clone() partialmessages.PartsMetadata {
	return MyPartsMetadata{metadata: m.metadata}
}

func (m MyPartsMetadata) Merge(a partialmessages.PartsMetadata) {
}

func (m MyPartsMetadata) IsSubset(partialmessages.PartsMetadata) bool {
	return false
}

type MyPartialMessage struct {
	groupID  []byte
	metadata []byte
}

func (m MyPartialMessage) GroupID() []byte {
	return m.groupID
}

func (m MyPartialMessage) PartialMessageBytes(remote peer.ID, partsMetadata partialmessages.PartsMetadata) (msg []byte, nextPartsMetadata partialmessages.PartsMetadata, _ error) {
	return nil, nil, nil
}

func (m MyPartialMessage) PartsMetadata() partialmessages.PartsMetadata {
	return MyPartsMetadata{metadata: m.metadata}
}

func publishPartialMessage(ps *pubsub.PubSub) {
	time.Sleep(time.Second * 5)
	const topicName = "logos-partial"
	topic, err := ps.Join(topicName)
	if err != nil {
		log.Fatalf("Failed to join topic: %v", err)
	}
	defer topic.Close()

	pm := MyPartialMessage{
		groupID:  []byte("interop-group"),
		metadata: []byte("1h2h3h"),
	}

	err = ps.PublishPartialMessage(topicName, pm, partialmessages.PublishOptions{})
	if err != nil {
		log.Fatalf("Failed to publish partial message topic: %v", err)
	} else {
		log.Printf("Partial message published")
	}
}

func main() {
	ctx := context.Background()
	priv, pid, err := loadOrCreateIdentity()
	if err != nil {
		log.Fatalf("Identity setup failed: %v", err)
	}

	host, err := libp2p.New(
		libp2p.Identity(priv),
		libp2p.ListenAddrStrings(
			// only use IPv6 addresses, as this test case also verifies
			// interoperability with IPv6. we do not want to accidentally
			// connect to an IPv4 address; therefore, it is not included.
			"/ip6/::/tcp/4040",
		),
	)
	if err != nil {
		log.Fatalf("Failed to create host: %v", err)
	}
	defer host.Close()

	pme := &partialmessages.PartialMessagesExtension{
		Logger: &slog.Logger{},
		ValidateRPC: func(from peer.ID, rpc *pb.PartialMessagesExtension) error {
			return nil
		},
		DecodePartsMetadata: func(_ peer.ID, rpc *pb.PartialMessagesExtension) (partialmessages.PartsMetadata, error) {
			return nil, nil
		},
		OnIncomingRPC: func(from peer.ID, rpc *pb.PartialMessagesExtension) error {
			return nil
		},
	}
	ps, err := pubsub.NewGossipSub(ctx, host, pubsub.WithPartialMessagesExtension(pme))
	if err != nil {
		log.Fatalf("Failed to create gossipsub: %v", err)
	}

	fmt.Println("Peer ID: ", pid.String())
	fmt.Println("Listen addresses: ", host.Addrs())
	fmt.Println("Go peer started.")

	publishPartialMessage(ps)
}
