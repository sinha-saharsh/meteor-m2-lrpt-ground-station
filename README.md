# Meteor-M2 LRPT Ground Station

A student-built satellite ground station for receiving and processing
Low Resolution Picture Transmission (LRPT) signals from the Russian
Meteor-M2 series polar-orbiting weather satellites.

The system combines a custom-built V-Dipole antenna, low-noise
amplification, an RTL-SDR V4 receiver, and MATLAB-based digital signal
processing to recover and analyze Meteor-M2 LRPT data.

---

## Project Overview

The objective of this project was to establish a functional satellite
ground station in Gandhinagar, Gujarat capable of receiving Meteor-M2
LRPT transmissions and processing the resulting RF data into
meteorological information.

The complete signal chain is:

Meteor-M2 Satellite
        ↓
137 MHz LRPT Downlink
        ↓
Custom V-Dipole Antenna
        ↓
Low-Noise Amplifier (LNA)
        ↓
RTL-SDR V4
        ↓
Complex IQ Samples
        ↓
QPSK/OQPSK Demodulation
        ↓
CADU Frame Synchronization
        ↓
VCDU Frame Parsing
        ↓
Meteorological Data
        ↓
MATLAB Analysis & Visualization

---

## Hardware

### Antenna

A custom V-Dipole antenna was fabricated for reception around
137.9 MHz.

Each dipole element was approximately 52.5 cm long, corresponding to
a quarter wavelength at the target frequency.

The two elements were arranged at approximately 120°–135° to improve
polarization matching with the satellite's transmitted signal.

### Low-Noise Amplifier

A 30–40 dB gain LNA was placed immediately after the antenna.

The LNA was externally powered because the particular module used in
the project did not support Bias-Tee power from the RTL-SDR.

### SDR

An RTL-SDR V4 was used to receive and digitize the satellite signal.

The receiver generated complex IQ samples for subsequent processing
in MATLAB.

### Ground Station

The complete hardware chain was:

Antenna → Coaxial Cable → LNA → RTL-SDR V4 → PC

---

## RF Configuration

| Parameter | Value |
|---|---|
| Satellite | Meteor-M2 |
| Signal | LRPT |
| Frequency | 137.900 MHz |
| Modulation | QPSK / OQPSK |
| Symbol Rate | 72 kSps |
| SDR Sample Rate | 1.44 MHz |
| SDR Bandwidth | 120 kHz |
| Antenna | V-Dipole |
| Antenna Element Length | 52.5 cm |
| LNA Gain | 30–40 dB |

Meteor-M2-2 operates at 137.100 MHz according to the decoder
configuration, while Meteor-M2 and Meteor-M2-3 are configured for
137.900 MHz.

---

## Satellite Tracking

Satellite passes were predicted using N2YO.com.

Passes with maximum elevations above 30° were prioritized to obtain
better line-of-sight conditions.

The antenna remained stationary while the satellite passed through
the receiving footprint.

---

## Signal Processing

The received signal was recorded as a complex 32-bit floating-point
(`.cf32`) IQ file.

The MATLAB processing pipeline consists of several stages.

### 1. IQ Data Acquisition

The `.cf32` recording is read as alternating I/Q floating-point
samples:

```text
I₁ Q₁ I₂ Q₂ I₃ Q₃ ...
