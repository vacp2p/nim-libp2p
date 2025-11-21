#!/bin/bash
docker compose down -v
rm -Rf vg-logs/*.heap
rm -Rf vg-logs/quic*
TRANSPORT=QUIC NUM_LIBP2P_NODES=10 docker compose up -d
