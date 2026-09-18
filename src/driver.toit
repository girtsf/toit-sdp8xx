// Copyright (C) 2026 Girts Folkmanis.
// Use of this source code is governed by an MIT-style license that can be
// found in the LICENSE file.

import io
import serial.device as serial

/** The I2C address of the SDP800 and SDP810. */
I2C-ADDRESS ::= 0x25
/** The I2C address of the SDP801 and SDP811. */
I2C-ADDRESS-ALT ::= 0x26

/** The product number of the SDP800-500Pa, without the revision byte. */
PRODUCT-SDP800-500PA ::= 0x03020100
/** The product number of the SDP810-500Pa, without the revision byte. */
PRODUCT-SDP810-500PA ::= 0x03020A00
/** The product number of the SDP801-500Pa, without the revision byte. */
PRODUCT-SDP801-500PA ::= 0x03020400
/** The product number of the SDP811-500Pa, without the revision byte. */
PRODUCT-SDP811-500PA ::= 0x03020D00
/** The product number of the SDP800-125Pa, without the revision byte. */
PRODUCT-SDP800-125PA ::= 0x03020200
/** The product number of the SDP810-125Pa, without the revision byte. */
PRODUCT-SDP810-125PA ::= 0x03020B00

/**
A single measurement of the sensor.
*/
class Measurement:
  /** The differential pressure, in Pascal. */
  pressure-pa/float
  /**
  The temperature of the sensor die, in degrees Celsius.

  This depends on the sensor's surroundings as well as on the gas, so it is
    not a reliable gas temperature.
  */
  sensor-die-temperature-c/float

  constructor --.pressure-pa --.sensor-die-temperature-c:

  stringify -> string:
    return "$(%.3f pressure-pa)Pa $(%.2f sensor-die-temperature-c)C"

/**
Driver for an SDP8xx sensor.

The sensor is either idle, measuring continuously (see $start-continuous), or
  asleep (see $enter-sleep-mode). Triggered measurements ($measure) and most
  other commands are only accepted in the idle state.

The driver does not own the device it is given, and closing that device is the
  caller's job.
*/
class Driver:
  static CMD-CONTINUOUS-MASS-FLOW-AVERAGE_ ::= 0x3603
  static CMD-CONTINUOUS-MASS-FLOW_ ::= 0x3608
  static CMD-CONTINUOUS-PRESSURE-AVERAGE_ ::= 0x3615
  static CMD-CONTINUOUS-PRESSURE_ ::= 0x361E
  static CMD-STOP-CONTINUOUS_ ::= 0x3FF9
  static CMD-TRIGGER-MASS-FLOW_ ::= 0x3624
  static CMD-TRIGGER-PRESSURE_ ::= 0x362F
  static CMD-ENTER-SLEEP_ ::= 0x3677
  static CMD-PRODUCT-ID-1_ ::= 0x367C
  static CMD-PRODUCT-ID-2_ ::= 0xE102

  static TEMPERATURE-SCALE_ ::= 200.0

  /** Time after a stop command before the sensor accepts a new one. */
  static STOP-DELAY-US_ ::= 500
  /** Time for the sensor to wake up, or to reset. */
  static WAKE-DELAY-MS_ ::= 2
  /**
  Time after starting continuous mode until the readings are accurate.

  The first reading is available after 8ms, but deviates by a few percent for
    another 12ms.
  */
  static CONTINUOUS-SETTLE-MS_ ::= 20
  /** The maximum duration of a triggered measurement. */
  static TRIGGERED-MS_ ::= 50

  /** The product family, the upper 16 bits of the product number. */
  static FAMILY_ ::= 0x0302

  device_/serial.Device
  is-continuous_/bool := false

  product-number_/int := 0
  serial-number_/int := 0

  /**
  Constructs a driver for the SDP8xx on the given device.

  The sensor can be in any state, as it survives a reset of the host: it is
    woken up if asleep, and stopped if measuring continuously. Afterwards it
    is idle.

  Throws if the device is not an SDP8xx.
  */
  constructor .device_:
    // A sleeping sensor wakes up on its address, which it does not
    // acknowledge. An awake one takes the stop command.
    write-command_ CMD-STOP-CONTINUOUS_ --wake
    sleep --ms=WAKE-DELAY-MS_
    // The stop command didn't reach a sleeping sensor.
    write-command_ CMD-STOP-CONTINUOUS_
    sleep (Duration --us=STOP-DELAY-US_)

    write-command_ CMD-PRODUCT-ID-1_
    write-command_ CMD-PRODUCT-ID-2_
    words := read-words_ 6
    product-number_ = (words[0] << 16) | words[1]
    serial-number_ = (words[2] << 48) | (words[3] << 32) | (words[4] << 16) | words[5]
    if product-number_ >> 16 != FAMILY_:
      throw "SDP8xx: unknown product $(%08x product-number_)"

  /**
  The 32-bit product number.

  The lowest byte is the revision and may change. Compare
    `product-number & 0xFFFF_FF00` against the `PRODUCT-*` constants, such as
    $PRODUCT-SDP810-500PA, to find the variant.
  */
  product-number -> int:
    return product-number_

  /**
  The 64-bit unique serial number.

  Toit integers are signed, so a serial number with the top bit set is
    negative.
  */
  serial-number -> int:
    return serial-number_

  /**
  Measures once and returns the result.

  The sensor must be idle. The measurement takes up to 50ms.

  If $mass-flow is true, uses the temperature compensation for mass flow
    instead of the one for differential pressure. Mass-flow compensation is
    advised when the sensor is used to measure a mass flow, as it then needs
    no correction for absolute pressure.
  */
  measure --mass-flow/bool=false -> Measurement:
    check-idle_
    write-command_ (mass-flow ? CMD-TRIGGER-MASS-FLOW_ : CMD-TRIGGER-PRESSURE_)
    sleep --ms=TRIGGERED-MS_
    return read-measurement_

  /**
  Starts continuous measurement.

  The sensor then updates its result every 0.5ms, and $read returns the latest
    one. Waits 20ms, until the first result is available and accurate.

  If $average is true, the sensor averages all values since the last $read,
    so that no information is lost however slowly the results are read. For
    the first 25ms this is the arithmetic mean; after that it is an
    exponential smoothing with a factor of 0.05.

  See $measure for $mass-flow.

  Use $stop-continuous to return to the idle state.
  */
  start-continuous --average/bool=true --mass-flow/bool=false -> none:
    check-idle_
    command := ?
    if mass-flow:
      command = average ? CMD-CONTINUOUS-MASS-FLOW-AVERAGE_ : CMD-CONTINUOUS-MASS-FLOW_
    else:
      command = average ? CMD-CONTINUOUS-PRESSURE-AVERAGE_ : CMD-CONTINUOUS-PRESSURE_
    write-command_ command
    is-continuous_ = true
    sleep --ms=CONTINUOUS-SETTLE-MS_

  /**
  Reads the latest result of the continuous measurement.

  Must only be called after $start-continuous. Results are updated every
    0.5ms; reading faster yields no new values.
  */
  read -> Measurement:
    if not is-continuous_: throw "SDP8xx: not measuring continuously"
    return read-measurement_

  /**
  Stops continuous measurement and returns the sensor to the idle state.

  Does nothing if the sensor is not measuring continuously.
  */
  stop-continuous -> none:
    if not is-continuous_: return
    write-command_ CMD-STOP-CONTINUOUS_
    is-continuous_ = false
    sleep (Duration --us=STOP-DELAY-US_)

  /** Whether the sensor is measuring continuously. */
  is-continuous -> bool:
    return is-continuous_

  /**
  Puts the sensor into sleep mode, where it draws about 1uA.

  The sensor must be idle. Stop continuous measurement first with
    $stop-continuous.

  Use $exit-sleep-mode to wake it up again. A new $Driver also wakes it.
  */
  enter-sleep-mode -> none:
    check-idle_
    write-command_ CMD-ENTER-SLEEP_

  /**
  Wakes the sensor from sleep mode, into the idle state.

  Takes 2ms. It is harmless to call this on a sensor that is already awake.
  */
  exit-sleep-mode -> none:
    // A sleeping sensor doesn't acknowledge its address, so the command never
    // reaches it. An awake, idle sensor ignores the stop command.
    write-command_ CMD-STOP-CONTINUOUS_ --wake
    sleep --ms=WAKE-DELAY-MS_

  /**
  Puts the sensor into a safe state.

  Stops continuous measurement if it is running.
  */
  close -> none:
    stop-continuous

  check-idle_ -> none:
    if is-continuous_: throw "SDP8xx: measuring continuously"

  /**
  Writes the 16-bit $command.

  If $wake is true, the sensor may be asleep: a NACK of the address is
    expected then and ignored.
  */
  write-command_ command/int --wake/bool=false -> none:
    bytes := #[command >> 8, command & 0xFF]
    if not wake:
      device_.write bytes
      return
    catch --unwind=(: it != "I2C_NACK"):
      device_.write bytes

  read-measurement_ -> Measurement:
    words := read-words_ 3
    raw-pressure := signed_ words[0]
    raw-temperature := signed_ words[1]
    scale := signed_ words[2]
    if scale <= 0: throw "SDP8xx: invalid scale factor $scale"
    return Measurement
        --pressure-pa=raw-pressure.to-float / scale
        --sensor-die-temperature-c=raw-temperature / TEMPERATURE-SCALE_

  static signed_ word/int -> int:
    return word >= 0x8000 ? word - 0x10000 : word

  /**
  Reads $count 16-bit words, each followed by a CRC byte.

  Returns the words as unsigned integers.
  */
  read-words_ count/int -> List:
    bytes := device_.read count * 3
    return List count: | i/int |
      offset := i * 3
      word := io.BIG-ENDIAN.uint16 bytes offset
      expected := crc8_ bytes[offset..offset + 2]
      if bytes[offset + 2] != expected:
        throw "SDP8xx: CRC mismatch"
      word

/** Computes the Sensirion CRC-8: polynomial 0x31, initialization 0xFF. */
crc8_ bytes/ByteArray -> int:
  crc := 0xFF
  bytes.do: | byte/int |
    crc ^= byte
    8.repeat:
      crc = (crc & 0x80) != 0 ? ((crc << 1) ^ 0x31) & 0xFF : (crc << 1) & 0xFF
  return crc
