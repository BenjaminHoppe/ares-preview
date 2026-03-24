# Ares Preview

A native macOS application for exploring Mars terrain using on-device neural super-resolution.

Ares enhances NASA orbital imagery of Mars using a 30 MB neural network (Ares SR v0.5.1) running on Apple's Neural Engine. Zoom continuously from orbit to surface, entirely offline.

Learn more at [Applied Curiosity](https://applied-curiosity.org)

## Requirements

- macOS 14 or newer 
- Apple Silicon

## Download

Download the DMG from the [latest release](https://github.com/applied-curiosity/ares-preview/releases/latest).

Large download (~1.4 GB). Contains pre-upscaled Mars terrain data.

## Build from source

Open `Ares Preview.xcodeproj` in Xcode 15+ and build for macOS.

## Data sources

- CTX mosaic: [Murray Lab, Caltech](https://murray-lab.caltech.edu/CTX/)
- HiRISE imagery: [University of Arizona](https://uahirise.org)
- Viking colour mosaic: USGS Astrogeology / NASA
- Model architecture: [Real-ESRGAN](https://github.com/xinntao/Real-ESRGAN)

## License

MIT
