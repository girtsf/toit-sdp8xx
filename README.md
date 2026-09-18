# sdp8xx

A Toit driver for the Sensirion
[SDP8xx](https://sensirion.com/products/catalog/series/sdp8xx) digital
differential pressure sensors (SDP800, SDP801, SDP810, SDP811; ±500Pa and
±125Pa).

## Usage

```toit
import i2c
import sdp8xx

main:
  bus := i2c.Bus --sda=21 --scl=22
  device := bus.device sdp8xx.I2C-ADDRESS  // I2C-ADDRESS-ALT for SDP801/SDP811.
  sensor := sdp8xx.Driver device

  // One-shot measurement, ~50ms, low power.
  print sensor.measure

  // Continuous measurement, averaged between reads.
  sensor.start-continuous
  sleep --ms=100
  print sensor.read
  sensor.stop-continuous
```

See [examples/i2c.toit](examples/i2c.toit) for a complete program.

## Features

| Feature                                     | API                                    | Command(s)                         |
| ------------------------------------------- | -------------------------------------- | ---------------------------------- |
| Triggered measurement                       | `measure`, `measure --mass-flow`       | `0x362F`, `0x3624`                 |
| Continuous measurement, "average till read" | `start-continuous`, `read`             | `0x3615`, `0x3603`                 |
| Continuous measurement, no averaging        | `start-continuous --no-average`        | `0x361E`, `0x3608`                 |
| Stop continuous measurement                 | `stop-continuous`, `close`             | `0x3FF9`                           |
| Sleep mode (~1uA)                           | `enter-sleep-mode`, `exit-sleep-mode`  | `0x3677`, address-only wake        |
| Product number and serial number            | `product-number`, `serial-number`      | `0x367C` + `0xE102`                |

Every word read is CRC-checked. Pressure is converted with the scale factor the
sensor reports, so the ±125Pa variants need no extra configuration.

## Notes

**The sensor keeps its state across a host reset.** It may still be asleep or
measuring continuously when the driver is constructed. The constructor wakes
and stops it, reads the product identifier, and throws if it is not an SDP8xx
(product family `0x0302`).

**Temperature is the die temperature**, not the gas temperature.

**Mass-flow compensation** (`--mass-flow`) is the right choice when the sensor
measures a mass flow, e.g. in a bypass; it needs no absolute-pressure
correction.

**Clock stretching is not used.** Triggered measurements wait the datasheet's
maximum measurement time (50ms) before reading.

**No soft reset.** The general call reset (address `0x00`) needs the bus, not
the device, and would reset every device on the bus that honours it.

## References

* [SDP8xx-Digital datasheet](https://sensirion.com/media/documents/90500156/6167E43B/Sensirion_Differential_Pressure_Datasheet_SDP8xx_Digital.pdf) (v1.1, April 2019)

## AI Disclosure

Robots wrote most of this.
