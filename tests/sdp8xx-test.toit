// Copyright (C) 2026 Girts Folkmanis.
// Use of this source code is governed by an MIT-style license that can be
// found in the LICENSE file.

/**
Tests the driver against $FakeChip, a command-level model of the SDP8xx.
*/

import expect show *
import sdp8xx
import serial.device as serial
import serial.registers as serial

IDLE ::= 0
CONTINUOUS ::= 1
SLEEPING ::= 2
TRIGGERED ::= 3
PRODUCT-ID ::= 4

class FakeChip implements serial.Device:
  state/int := IDLE
  /** Every command written, oldest first. */
  commands/List := []
  product-number/int := 0x03020A01
  serial-number/int := 0x0102_0304_0506_0708
  raw-pressure/int := 0
  raw-temperature/int := 0
  scale/int := 60
  corrupt-next-read/bool := false
  prepared-product-id_/bool := false

  registers -> serial.Registers: throw "UNUSED"

  write bytes/ByteArray -> none:
    if state == SLEEPING:
      // The address wakes the sensor, but isn't acknowledged.
      state = IDLE
      throw "I2C_NACK"
    expect-equals 2 bytes.size
    command := (bytes[0] << 8) | bytes[1]
    commands.add command
    if state == CONTINUOUS and command != 0x3FF9:
      throw "fake: command $(%04x command) while measuring"
    if command == 0x3FF9:
      state = IDLE
    else if command == 0x3603 or command == 0x3608 or command == 0x3615 or command == 0x361E:
      state = CONTINUOUS
    else if command == 0x3624 or command == 0x362F:
      state = TRIGGERED
    else if command == 0x3677:
      state = SLEEPING
    else if command == 0x367C:
      prepared-product-id_ = true
    else if command == 0xE102:
      expect prepared-product-id_
      prepared-product-id_ = false
      state = PRODUCT-ID
    else:
      throw "fake: unknown command $(%04x command)"

  read amount/int -> ByteArray:
    words := ?
    if state == PRODUCT-ID:
      expect-equals 18 amount
      words = [
        product-number >> 16,
        product-number & 0xFFFF,
        (serial-number >> 48) & 0xFFFF,
        (serial-number >> 32) & 0xFFFF,
        (serial-number >> 16) & 0xFFFF,
        serial-number & 0xFFFF,
      ]
      state = IDLE
    else if state == CONTINUOUS or state == TRIGGERED:
      expect-equals 9 amount
      words = [raw-pressure & 0xFFFF, raw-temperature & 0xFFFF, scale & 0xFFFF]
      if state == TRIGGERED: state = IDLE
    else:
      throw "I2C_NACK"
    result := ByteArray amount
    words.size.repeat: | i/int |
      result[i * 3] = words[i] >> 8
      result[i * 3 + 1] = words[i] & 0xFF
      result[i * 3 + 2] = crc8 result[i * 3..i * 3 + 2]
    if corrupt-next-read:
      corrupt-next-read = false
      result[2] ^= 1
    return result

crc8 bytes/ByteArray -> int:
  crc := 0xFF
  bytes.do: | byte/int |
    crc ^= byte
    8.repeat:
      crc = (crc & 0x80) != 0 ? ((crc << 1) ^ 0x31) & 0xFF : (crc << 1) & 0xFF
  return crc

main:
  test-crc
  test-construct-idle
  test-construct-continuous
  test-construct-sleeping
  test-construct-wrong-product
  test-measure
  test-measure-mass-flow
  test-continuous
  test-sleep
  test-crc-mismatch

test-crc:
  // The example from the datasheet.
  expect-equals 0x92 (crc8 #[0xBE, 0xEF])

test-construct-idle:
  chip := FakeChip
  sensor := sdp8xx.Driver chip
  expect-equals [0x3FF9, 0x3FF9, 0x367C, 0xE102] chip.commands
  expect-equals 0x03020A01 sensor.product-number
  expect-equals sdp8xx.PRODUCT-SDP810-500PA (sensor.product-number & 0xFFFF_FF00)
  expect-equals 0x0102_0304_0506_0708 sensor.serial-number
  expect-not sensor.is-continuous

test-construct-continuous:
  chip := FakeChip
  chip.state = CONTINUOUS
  sdp8xx.Driver chip
  expect-equals IDLE chip.state

test-construct-sleeping:
  chip := FakeChip
  chip.state = SLEEPING
  sensor := sdp8xx.Driver chip
  // The first stop command was lost to the wake-up.
  expect-equals [0x3FF9, 0x367C, 0xE102] chip.commands
  expect-equals 0x03020A01 sensor.product-number

test-construct-wrong-product:
  chip := FakeChip
  chip.product-number = 0x03010188  // An SDP3x.
  expect-throw "SDP8xx: unknown product 03010188": sdp8xx.Driver chip

test-measure:
  chip := FakeChip
  sensor := sdp8xx.Driver chip
  chip.commands.clear
  chip.raw-pressure = -1230  // -20.5Pa at scale 60.
  chip.raw-temperature = 4700  // 23.5C.
  m := sensor.measure
  expect-equals [0x362F] chip.commands
  expect-equals -20.5 m.pressure-pa
  expect-equals 23.5 m.sensor-die-temperature-c

  // The 125Pa variants report a different scale factor.
  chip.scale = 240
  chip.raw-pressure = 240 * 100
  chip.raw-temperature = -200 * 10
  m = sensor.measure
  expect-equals 100.0 m.pressure-pa
  expect-equals -10.0 m.sensor-die-temperature-c

test-measure-mass-flow:
  chip := FakeChip
  sensor := sdp8xx.Driver chip
  chip.commands.clear
  sensor.measure --mass-flow
  expect-equals [0x3624] chip.commands

test-continuous:
  [
    [true, false, 0x3615],
    [false, false, 0x361E],
    [true, true, 0x3603],
    [false, true, 0x3608],
  ].do: | entry/List |
    chip := FakeChip
    sensor := sdp8xx.Driver chip
    chip.commands.clear
    sensor.start-continuous --average=entry[0] --mass-flow=entry[1]
    expect-equals [entry[2]] chip.commands
    expect sensor.is-continuous

    chip.raw-pressure = 60 * 3
    expect-equals 3.0 sensor.read.pressure-pa
    chip.raw-pressure = 60 * 4
    expect-equals 4.0 sensor.read.pressure-pa

    expect-throw "SDP8xx: measuring continuously": sensor.measure
    expect-throw "SDP8xx: measuring continuously": sensor.enter-sleep-mode
    expect-throw "SDP8xx: measuring continuously": sensor.start-continuous

    sensor.stop-continuous
    expect-not sensor.is-continuous
    expect-equals IDLE chip.state
    expect-throw "SDP8xx: not measuring continuously": sensor.read

    // Stopping twice is harmless, and close stops.
    sensor.stop-continuous
    sensor.start-continuous
    sensor.close
    expect-equals IDLE chip.state

test-sleep:
  chip := FakeChip
  sensor := sdp8xx.Driver chip
  sensor.enter-sleep-mode
  expect-equals SLEEPING chip.state
  sensor.exit-sleep-mode
  expect-equals IDLE chip.state
  sensor.measure
  // Waking an awake sensor is harmless.
  sensor.exit-sleep-mode
  expect-equals IDLE chip.state

test-crc-mismatch:
  chip := FakeChip
  sensor := sdp8xx.Driver chip
  chip.corrupt-next-read = true
  expect-throw "SDP8xx: CRC mismatch": sensor.measure
