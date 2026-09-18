// Copyright (C) 2026 Girts Folkmanis.
// Use of this source code is governed by an MIT-style license that can be
// found in the LICENSE file.

/**
Reads an SDP8xx in triggered mode, then in continuous mode.
*/

import i2c
import sdp8xx

main:
  bus := i2c.Bus --sda=21 --scl=22
  device := bus.device sdp8xx.I2C-ADDRESS
  sensor := sdp8xx.Driver device
  print "Product: $(%08x sensor.product-number), serial: $(%016x sensor.serial-number)"

  print "Triggered: $sensor.measure"

  // With averaging, each read returns the average since the previous one.
  sensor.start-continuous
  10.repeat:
    sleep --ms=100
    print "Continuous: $sensor.read"
  sensor.stop-continuous

  sensor.enter-sleep-mode
  device.close
  bus.close
