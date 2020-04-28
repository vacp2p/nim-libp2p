#! /bin/bash
read -p "[Path] [App Name] [Stack Address] [Relative Address] " path appName runtimeAddress relativeAddress
loadAddress=`echo "obase=16;ibase=10;$((runtimeAddress-relativeAddress))" | bc`
atos -o $path/Payload/$appName.app/$appName -l $loadAddress $runtimeAddress -arch armv7
