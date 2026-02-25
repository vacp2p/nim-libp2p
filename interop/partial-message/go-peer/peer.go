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
	"github.com/libp2p/go-libp2p/core/network"
	peer "github.com/libp2p/go-libp2p/core/peer"
	"github.com/multiformats/go-multiaddr"
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
	clone := make([]byte, len(m.metadata))
	copy(clone, m.metadata)

	return MyPartsMetadata{metadata: clone}
}

func (m MyPartsMetadata) Merge(a partialmessages.PartsMetadata) {
	m.metadata = append(m.metadata, a.Encode()...)
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

func publishPartialMessage(ps *pubsub.PubSub, doneC chan struct{}) {
	defer close(doneC)

	const topicName = "logos-partial"
	topic, err := ps.Join(topicName, pubsub.SupportsPartialMessages())
	if err != nil {
		log.Fatalf("Failed to join topic: %v", err)
	}

	subs, err := topic.Subscribe()
	if err != nil {
		log.Fatalf("Failed to subscribe to topic: %v", err)
	}

	go func() {
		for {
			msg, err := subs.Next(context.Background())
			if err != nil {
				log.Printf("Subscription ended: %v", err)
				return
			}
			log.Printf("Received message on %s from %s", msg.GetTopic(), msg.ReceivedFrom)
		}
	}()

	time.Sleep(2 * time.Second)

	defer topic.Close()

	pm := MyPartialMessage{
		groupID:  []byte("interop-group"),
		metadata: []byte{1, 'h', 2, 'h', 3, 'h'},
	}

	err = ps.PublishPartialMessage(topicName, pm, partialmessages.PublishOptions{})
	if err != nil {
		log.Fatalf("Failed to publish partial message topic: %v", err)
	} else {
		log.Printf("Partial message published")
	}
}

type connectionNotifiee struct {
	onConnected func()
}

func (n *connectionNotifiee) Listen(network.Network, multiaddr.Multiaddr)      {}
func (n *connectionNotifiee) ListenClose(network.Network, multiaddr.Multiaddr) {}
func (n *connectionNotifiee) OpenedStream(network.Network, network.Stream)     {}
func (n *connectionNotifiee) ClosedStream(network.Network, network.Stream)     {}
func (n *connectionNotifiee) Disconnected(_ network.Network, conn network.Conn) {
}
func (n *connectionNotifiee) Connected(_ network.Network, conn network.Conn) {
	fmt.Println("Peer connected")
	n.onConnected()
}

func main() {
	doneC := make(chan struct{})
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
			"/ip6/::/tcp/4141",
		),
	)
	if err != nil {
		log.Fatalf("Failed to create host: %v", err)
	}
	defer host.Close()

	handler := slog.NewTextHandler(os.Stdout, &slog.HandlerOptions{
		Level: slog.LevelInfo, // minimum log level
	})

	pme := &partialmessages.PartialMessagesExtension{
		Logger: slog.New(handler),
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

	// wait for peer to connect then publish partial message
	host.Network().Notify(&connectionNotifiee{
		onConnected: func() {
			go publishPartialMessage(ps, doneC)
		},
	})

	fmt.Println("Peer ID: ", pid.String())
	fmt.Println("Listen addresses: ", host.Addrs())
	fmt.Println("Go peer started.")

	<-doneC
}
