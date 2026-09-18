// Copyright (C) 2026 Girts Folkmanis.
// Use of this source code is governed by an MIT-style license that can be
// found in the LICENSE file.

import .driver
export *

/**
Driver for the Sensirion SDP8xx digital differential pressure sensors.

The family consists of the SDP800, SDP801, SDP810 and SDP811, in ±500Pa and
  ±125Pa versions. The sensors measure differential pressure and the
  temperature of the sensor die over I2C. The SDP800 and SDP810 use
  $I2C-ADDRESS; the SDP801 and SDP811 use $I2C-ADDRESS-ALT.

The sensor has two ways of measuring:
- Triggered, with $Driver.measure: one measurement of about 45ms, after which
  the sensor returns to idle. Best when power matters more than speed.
- Continuous, with $Driver.start-continuous and $Driver.read: the sensor
  updates its result every 0.5ms. With averaging, each read returns the
  average since the previous one, so slow readers lose no information.

Between measurements, $Driver.enter-sleep-mode reduces the current to about
  1uA.

# Examples
```
import i2c
import sdp8xx

main:
  bus := i2c.Bus --sda=21 --scl=22
  device := bus.device sdp8xx.I2C-ADDRESS
  sensor := sdp8xx.Driver device
  measurement := sensor.measure
  print "$(%.2f measurement.pressure-pa)Pa, $(%.1f measurement.sensor-die-temperature-c)C"
```
*/
