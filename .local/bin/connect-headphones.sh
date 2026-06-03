#!/bin/bash

DEVICE="08:12:87:39:0D:96"

# make sure bluetooth is on
bluetoothctl power on

# disconnect from anything stale
bluetoothctl disconnect "$DEVICE" >/dev/null 2>&1

# small delay so device releases old connection
sleep 1

# attempt reconnect
bluetoothctl connect "$DEVICE"
