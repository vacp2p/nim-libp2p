// Nim-LibP2P
// Copyright (c) 2023-2025 Status Research & Development GmbH
// Licensed under either of
//  * Apache License, version 2.0 ([LICENSE-APACHE](LICENSE-APACHE))
//  * MIT license ([LICENSE-MIT](LICENSE-MIT))
// at your option.
// This file may not be copied, modified, or distributed except according to
// those terms.

use libp2p::{
    futures::StreamExt,
    identity,
    kad::{self, store::MemoryStore, Mode},
    noise,
    swarm::{NetworkBehaviour, StreamProtocol, SwarmEvent},
    tcp, yamux, Multiaddr, PeerId, SwarmBuilder,
};
use std::{error::Error, fs, time::Duration};
use tracing_subscriber::{filter::EnvFilter, fmt};

fn init_tracing() {
    let filter = EnvFilter::try_from_default_env().unwrap_or_else(|_| EnvFilter::new("debug"));
    fmt().with_env_filter(filter).init();
}

#[derive(NetworkBehaviour)]
struct MyBehaviour {
    kademlia: libp2p::kad::Behaviour<MemoryStore>,
    identify: libp2p::identify::Behaviour,
}

#[tokio::main]
async fn main() -> Result<(), Box<dyn Error>> {
    init_tracing();

    // Load or generate identity
    let local_key = if let Ok(bytes) = fs::read("rust.key") {
        identity::Keypair::from_protobuf_encoding(&bytes)?
    } else {
        let k = identity::Keypair::generate_ed25519();
        fs::write("rust.key", k.to_protobuf_encoding()?)?;
        k
    };

    let local_peer_id = PeerId::from(local_key.public());
    println!("Local PeerId: {local_peer_id}");
    fs::write("peer.id", local_peer_id.to_string())?;

    // Build Kademlia behaviour
    let mut kad_cfg = kad::Config::new(StreamProtocol::new("/ipfs/kad/1.0.0"));
    kad_cfg.set_query_timeout(Duration::from_secs(5 * 60));
    let store = MemoryStore::new(local_peer_id);
    let kademlia = libp2p::kad::Behaviour::with_config(local_peer_id, store, kad_cfg);

    let identify = libp2p::identify::Behaviour::new(libp2p::identify::Config::new(
        "/ipfs/id/1.0.0".to_string(),
        local_key.public(),
    ));

    let behaviour = MyBehaviour { kademlia, identify };

    // Build the swarm
    let mut swarm = SwarmBuilder::with_existing_identity(local_key)
        .with_tokio()
        .with_tcp(
            tcp::Config::default(),
            noise::Config::new,
            yamux::Config::default,
        )?
        .with_behaviour(|_| behaviour)?
        .build();

    swarm.behaviour_mut().kademlia.set_mode(Some(Mode::Server));

    // Listen on local address
    let listen_addr: Multiaddr = "/ip4/127.0.0.1/tcp/4141".parse()?;
    swarm.listen_on(listen_addr)?;

    loop {
        match swarm.select_next_some().await {
            SwarmEvent::NewListenAddr { address, .. } => {
                println!("Listening on {address}");
            }

            SwarmEvent::Behaviour(MyBehaviourEvent::Kademlia(event)) => {
                if let kad::Event::OutboundQueryProgressed { result, .. } = event {
                    match result {
                        kad::QueryResult::PutRecord(res) => match res {
                            Ok(ok) => {
                                if ok.key.as_ref() == b"rust-peer" {
                                    println!("Received PUT_VALUE for rust-peer!");
                                    fs::File::create("success")?;
                                }
                            }
                            Err(err) => {
                                eprintln!("PUT_RECORD failed: {:?}", err);
                            }
                        },
                        _ => {} // ignore other query results
                    }
                }
            }

            SwarmEvent::Behaviour(MyBehaviourEvent::Identify(event)) => {
                println!("Identify event: {:?}", event);
            }

            _ => {}
        }
    }
}
