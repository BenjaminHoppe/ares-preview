# Ares Preview

Ares enhances NASA orbital imagery of Mars using on-device neural super-resolution running on your Mac's Neural engine. 

Requires Apple Silicon and macOS 14 or newer.

[Download Ares Preview v0.1](https://github.com/BenjaminHoppe/ares-preview/releases/tag/v0.1).



_Note: Ares Preview is ~1.4 GB due to shipping pre-upscaled HiRISE imagery (more below)._

# Summary 

A TLDR, 2 minute read. 

Since 2006, NASA's Mars Reconnaissance Orbiter has been building the most detailed photographic record of another planet in history. The public archive now exceeds 110 terabytes. Existing tools for exploring this data are web-based and built for researchers. No native, locally running application exists for browsing it on your own hardware.

This research preview is an attempt to change that for one small corner of the planet.

Ares SR v0.5.1 is a 30 MB super-resolution model fine-tuned on 542,472 image patches from 1,910 HiRISE sites across Mars. It runs entirely on-device via Apple's Neural Engine, enhancing compressed orbital imagery 4x in resolution from 1 metre per pixel down to 25 centimetres, and from 25 centimetres down to approximately 6. The model achieves 29.05 dB PSNR and 0.7428 SSIM on held-out validation data.

Eight model versions were trained over five days at a total compute cost of $28 USD. Three approaches failed. The main finding: adjusting the loss function on the same dataset improved PSNR by 4 dB. More data was never the bottleneck.

The model is deployed in Ares, a native macOS app built with SwiftUI, covering Chryse Planitia and Ares Vallis, the region where Pathfinder landed in 1997. Ares runs entirely offline, requires no account, and ships with pre-enhanced imagery ready to explore on launch.

All terms, metrics, and methodology are defined in full below.

# Compressing Mars: on-device terrain enhancement with a 30 MB neural network

## Table of Contents

- [The most photographed planet nobody can explore](#the-most-photographed-planet-nobody-can-explore)
- [Teaching Real-ESRGAN how to see Mars](#teaching-real-esrgan-how-to-see-mars)
- [Eight versions, $28, and some patience](#eight-versions-28-and-some-patience)
- [Ares: Exploring Mars on Apple Silicon](#ares-exploring-mars-on-apple-silicon)
- [In closing](#in-closing)
- [About Applied Curiosity](#about-applied-curiosity)
- [Sources](#sources)
- [Licence](#licence)

## The most photographed planet nobody can explore

Mars is the most documented planet in the solar system after Earth. NASA's Mars Reconnaissance Orbiter (MRO) has been photographing it continuously since November 2006. The Context Camera (CTX) alone has imaged more than 99% of the surface at 6 metres per pixel, that's 5.7 trillion pixels and roughly 11 terabytes of greyscale terrain imagery. The High Resolution Imaging Science Experiment (HiRISE) camera has captured thousands of targeted sites at 25 centimetres per pixel, detailed enough to see landers we've sent to the red planet. Combined, this publicly available data exceeds 110 terabytes.

CTX and HiRISE files are multi-gigabyte, the formats are not your standard jpeg, but JP2 images embedded with planetary map projections that require special software just to open. Existing tools for browsing this data are web-based, cloud based models exist for viewing large amounts of CTX and HiRISE data at once, but what if you could do this locally? 

Rather than downloading the full dataset, what if you could compress the imagery and reconstruct the detail on-device using a model trained to understand what Martian terrain looks like at high resolution? 

That's what this research preview sets out to answer. Not if you can reconstruct what is known as ground truth (imagery accurate to the degree that it is indistinguishable from the source), but if you can reconstruct Mars orbital imagery at all using an off-the-shelf super-resolution model that can run on consumer-grade-hardware. 

The rise of AI-assisted development, in combination with on-device inference hardware like Apple Silicon, has made it possible to explore a new use case for upscaling planetary imagery with the constraint that it is able to do so entirely offline, on device,  and in a matter of weeks rather than months. 

## Teaching Real-ESRGAN how to see Mars

Real-ESRGAN is an open-source super-resolution model architecture originally designed for enhancing photographic imagery of faces, landscapes, and textures. It was not built for planetary science. It has never seen a crater, and it was trained on the kind of imagery you'd find on the internet, not in NASA's Planetary Data System.

So why use it? Because building a custom model from scratch is far beyond what's achievable in a few short weeks. The question this work sets out to answer is simple: is super-resolution on Mars orbital imagery even possible on consumer hardware? For that, Real-ESRGAN is the obvious starting point.

To measure how well upscaling works, two metrics are commonly used in this field. Peak Signal-to-Noise Ratio (PSNR) measures pixel-level reconstruction accuracy, or how closely the model's output matches the original high-resolution image on a per-pixel basis. It is measured in decibels (dB), higher is better. Structural Similarity Index (SSIM) measures perceptual similarity, or how closely the output matches the structure, contrast, and texture of the original in a way that better reflects how humans perceive image quality. SSIM ranges from 0 to 1, where 1 is a perfect match.

Both metrics have limitations. They measure how closely enhanced output matches a synthetically downsampled reference, not how closely it matches actual Martian surface detail. The model has never been validated against rover imagery or surface level measurements. It is also worth noting that Real-ESRGAN's architecture and loss functions were optimized for photographic data, which has different characteristics to planetary greyscale imagery (more colour variation, more contrast, more familiar textures). 

A model purpose-built for planetary data, trained on a broader geographic distribution, with a loss function tuned for geological fidelity rather than photographic quality, would likely produce meaningfully better results.

## Eight versions, $28, and some patience 

A total of eight versions of the model were trained over five days. The first three ran on an M4 Pro MacBook Pro. Before spending money on cloud compute, the goal was to prove the approach worked at all.

Throughout the versions, model output is compared against bicubic upscaling, a standard interpolation method that smooths pixels rather than predicting new detail, and the baseline for most traditional image scaling. Models are trained on tiles, small fixed-size image patches cropped from HiRISE imagery, because feeding a full multi-gigabyte image into a model at once is not practical.

v0.1 used 12,000 tiles from two HiRISE images of the Pathfinder site, trained in roughly 4.5 hours on the MacBook. It worked, but had more or less memorized the two images it was trained on. Impressive, but not scalable.

v0.2 and v0.2.1 paired real CTX and HiRISE images from the same locations, trained over about 9.5 hours locally. The cameras differ enough in optics, lighting, and atmospheric response that the model learned to map tone between instruments rather than recover detail. SSIM collapsed to 0.18. v0.3 corrected this with synthetic downsampling (a technique where high-resolution images are artificially degraded to create training pairs, so the model learns to reverse a known process rather than reconcile two different cameras) across 40 diverse HiRISE sites, completing in about 2.5 hours. 

v0.3 achieved an SSIM of 0.64, notably above the 0.607 SSIM published by the MADNet team at University College London. It is worth noting that MADNet tackles a harder problem (cross-instrument super-resolution combined with elevation estimation) on different data with different evaluation methods. That said, the two are not directly comparable.

With the approach validated locally, v0.4 moved to a cloud-rented NVIDIA A100 (an 80 GB VRAM GPU, roughly 10x more powerful than the MacBook's Neural Engine). The dataset grew to 542,472 tiles from 1,910 HiRISE images across Mars. Training completed in about 90 minutes. The model performed worse than what bicubic upscaling could produce. 

More data didn't help because the bottleneck was never the data. The GAN loss configuration (a component of the training process that uses a second "critic" network to push the model toward sharper, more realistic-looking output) was set too aggressively, causing the model to optimize for sharpness over accuracy.

v0.5 kept everything from v0.4 but removed the GAN entirely. The GAN loss was the problem. Without it, pixel loss and perceptual loss could do their job cleanly. PSNR jumped 4 dB on the same 542,472 tiles, trained in roughly 1.5 hours. The loss function was the bottleneck all along, not the data.

v0.5.1 reintroduced the GAN at a fraction of the original weight (0.01), fine-tuned from the v0.5 checkpoint in about 1 hour. This is the production model, Ares SR v0.5.1. The best checkpoint was saved at just 2,500 iterations. Every version trained beyond that performed worse. v0.5.2 briefly explored reducing the perceptual loss weight, producing the most stable but weakest results of the three.

Total cost: $28 USD, and a lot of patience. 

## Ares: Exploring Mars on Apple Silicon

Ares is a native macOS application built to put the results of this research into a usable form. It is not a scientific tool. It is an exploration interface, a way to experience what enhanced Mars orbital imagery actually looks like when you can move through it continuously, from regional scale down to individual rocks.

The preview covers Chryse Planitia and Ares Vallis, the region where NASA's Pathfinder lander touched down on July 4, 1997. Three resolution tiers are available as you zoom in:

|Tier|Source|Enhanced resolution|Coverage|
|---|---|---|---|
|Tier 1 — Chryse Planitia|CTX mosaic|~6 m/px|1,510 × 944 km|
|Tier 2 — Ares Vallis|HiRISE downsampled|~25 cm/px|4.06 × 13.90 km|
|Tier 3 — Pathfinder site|HiRISE native|~6 cm/px|2.7 × 1.7 km|

The model enhances Tiers 2 and 3 only. Tier 1 CTX data at 6 m/px performs adequately without enhancement at the scale it is viewed.

Tiers 1 and 2 are compression recovery, meaning that the model reconstructs detail that existed in the source data but was removed through downsampling. Tier 3 is different in kind. It takes HiRISE imagery at its native 25 cm/px resolution and pushes 4× past what the instrument actually captured. Pathfinder, its parachute and backshell are clearly visible in the upscaled output. Any detail finer than 25 cm/px is a prediction, not a recovery.

For this preview, the enhanced imagery ships pre-upscaled rather than running inference live on launch. The Tier 1 and Tier 2 tiles were enhanced in advance on an M4 Pro MacBook Pro in approximately 15 minutes and bundled with the app for an instant experience. The model is included and can be run locally should a curious mind choose to do so.

An altitude scale bar on the left side of the viewport shows your equivalent viewing altitude above the surface, derived from the geographic extent of what is visible. The zoom range runs from roughly ISS orbit altitude down to the height of a 10-storey building, with familiar Earth landmarks as reference points along the way.

A live telemetry panel displays real planetary data computed locally from published Mars orbital mechanics (Mars Coordinated Time, distance to Earth, light delay, orbital velocity), updated in real time accurate within 1%. No API or internet connection required.
## In closing 

The question was simple: could you take an off-the-shelf super-resolution model, fine-tune it on Martian terrain, and run it locally inside a native Mac app on hardware you already own? The answer, it turns out, is yes, with caveats and limitations, but undeniably yes. 

Modern open-source super-resolution frameworks, publicly available planetary data, and AI-assisted development made it possible to answer that question in a fraction of the time it would have taken otherwise.

Chryse Planitia is a small corner of a very large planet. One percent is a start.

## About Applied Curiosity 

Applied Curiosity is an independent research lab producing ideas and tools at the intersection of design and science, with the belief that the best way to understand complex ideas is to make them visible, interactive, and approachable. 

Keep in touch on X/Twitter [@applied_curi](https://x.com/applied_curi)
## Sources

- Murray Lab CTX Global Mosaic — Murray Lab, Caltech. [murray-lab.caltech.edu/CTX](https://murray-lab.caltech.edu/CTX)
- HiRISE imagery — HiRISE, University of Arizona. [uahirise.org](https://www.uahirise.org)
- Viking colour mosaic — USGS Astrogeology / NASA Planetary Data System
- MOLA elevation data — NASA Planetary Data System
- Real-ESRGAN — Xintao Wang et al. [github.com/xinntao/Real-ESRGAN](https://github.com/xinntao/Real-ESRGAN)
- Allison, M. and McEwen, A. (2000). A post-Pathfinder evaluation of areocentric solar coordinates with improved timing recipes for Mars seasonal/diurnal climate studies. *Planetary and Space Science*, 48, 215–235.
- Tao, Y., Muller, J-P., Conway, S.J. and Xiong, S. (2021). MADNet 2.0: Pixel-Scale Topography Retrieval from Single-View Orbital Imagery of Mars Using Deep Learning. _Remote Sensing_, 13(21), 4220. [doi.org/10.3390/rs13214220](https://doi.org/10.3390/rs13214220)
## Licence 

The Ares Preview source code is released under the MIT licence. See [Licence](https://github.com/BenjaminHoppe/ares-preview?tab=MIT-1-ov-file) for details.
Source data is derived from publicly available NASA imagery and is subject to NASA's open data policies. The Real-ESRGAN architecture is used under the BSD 3-Clause licence.
