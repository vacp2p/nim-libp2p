#!/bin/sh

nim c -d:chronicles_colors=None --threads:on -d:metrics -d:libp2p_network_protocols_metrics -d:release main && rm -rf shadow.data/ && shadow shadow.yaml && grep -rne 'milliseconds\|BW' shadow.data/ > latencies
