#!/bin/bash

CLONE=`virsh list --inactive | tail -n +3 | awk '{print $2}' | head -n -1 | zenity --list --title "VM Selection" --column "VM" --text "Select a domain to clone"`
NAME=`zenity --entry --text "Enter new VM name (no spaces)" --title "New Domain"`
virsh vol-delete $NAME.qcow2 ram
./clone-vm.pl --domain $CLONE --clone $NAME --cowpool ram
