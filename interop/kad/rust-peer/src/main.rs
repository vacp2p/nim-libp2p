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
    kad::{self, store::MemoryStore},
    noise,
    swarm::SwarmEvent,
    tcp, yamux, Multiaddr, PeerId,
};
use std::{error::Error, fs};
use tracing_subscriber::{filter::EnvFilter, fmt};
fn init_tracing() {
    // Read RUST_LOG from environment, fallback to "info"
    let filter = EnvFilter::try_from_default_env().unwrap_or_else(|_| EnvFilter::new("debug"));
    fmt().with_env_filter(filter).init();
}

#[tokio::main]
async fn main() -> Result<(), Box<dyn Error>> {
    init_tracing();
    let local_key = if let Ok(bytes) = std::fs::read("rust.key") {
        identity::Keypair::from_protobuf_encoding(&bytes)?
    } else {
        let k = identity::Keypair::generate_ed25519();
        std::fs::write("rust.key", k.to_protobuf_encoding()?)?;
        k
    };

    let local_peer_id = PeerId::from(local_key.public());
    println!("Local PeerId: {local_peer_id}");

    fs::write("peer.id", local_peer_id.to_string())?;

    let mut swarm = libp2p::SwarmBuilder::with_existing_identity(local_key)
        .with_tokio()
        .with_tcp(
            tcp::Config::default(),
            noise::Config::new,
            yamux::Config::default,
        )?
        .with_behaviour(|_| kad::Behaviour::new(local_peer_id, MemoryStore::new(local_peer_id)))?
        .build();

    let listen_addr: Multiaddr = "/ip4/127.0.0.1/tcp/4141".parse()?;
    swarm.listen_on(listen_addr)?;

    loop {
        match swarm.select_next_some().await {
            // SwarmEvent::Behaviour(kad::Event::OutboundQueryProgressed { result, .. }) => {
            //     if let kad::QueryResult::PutRecord(res) = result {
            //         if res?.key.as_ref() == b"rust-peer" {
            //             println!("Received PUT_VALUE for rust-peer!");
            //             fs::File::create("success")?;
            //         }
            //     }
            // }
            // SwarmEvent::NewListenAddr { address, .. } => {
            //     println!("Listening on {address}");
            // }
            _ => {}
        }
    }
}
