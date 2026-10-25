# HOOPICS models

HOOPICS 0.2 enlarges pictures with two models from [NERVE](https://huggingface.co/Phips/NERVE), a small
super-resolution network by Philip Hofmann. HOOPICS downloads them once, as `hoopics-models-nerve-r1.zip`
from this repository's releases, and checks the SHA-256 of the ZIP and of every model file in it.

| Picture type | Model | Files |
|---|---|---|
| Anime & illustration | NERVE 4x OTF fidelity | `4x_NERVE_OTF_fidelity.fp32.onnx`, `.fp16.onnx` |
| Photo | NERVE 4x OTF GAN | `4x_NERVE_OTF_gan.fp32.onnx`, `.fp16.onnx` |

Both enlarge 4x and have 1.8 million parameters: a 5x5 convolution, 24 residual blocks of two 3x3
convolutions, a sub-pixel output layer, and a bicubic copy of the input added to the result. "OTF" means
the author trained them on pictures degraded on the fly (blur, noise, JPEG, downscaling), so they also
clean up the input. The fidelity model stays close to the input; the GAN model, trained further with a
discriminator, draws sharper detail.

## Source and license

- Author: Philip Hofmann (Switzerland), from the author's repository at commit
  `3619eb1a67d775d9357bdb808336700e681b3eaf`.
- License: Apache License 2.0 for the code and the trained weights, as the repository states. The text
  and a notice of what HOOPICS changed are in the ZIP's `licenses` folder and in
  [THIRD_PARTY_NOTICES.md](../THIRD_PARTY_NOTICES.md#models).
- Training data: the author states that the models were trained only on
  [Phips/lucid-cc0-v2-hc-512](https://huggingface.co/datasets/Phips/lucid-cc0-v2-hc-512), 512 px tiles
  cut from photos on [PxHere](https://pxhere.com/en/license). PxHere publishes every photo under CC0;
  its photos are uploaded by users, so that label has not been checked photo by photo.
- Training code: [traiNNer-redux](https://github.com/the-database/traiNNer-redux), with degradations in
  the style of Real-ESRGAN. Neither is part of the models or of HOOPICS.

## Conversion

[`dev/models/Build-Models.ps1`](../dev/models/Build-Models.ps1) downloads the checkpoints, checks them
against pinned SHA-256s and runs [`dev/models/nerve_to_onnx.py`](../dev/models/nerve_to_onnx.py), which
reads the `.safetensors` files with numpy alone (no torch, no pickle) and writes ONNX opset 17:

- fp32 keeps the published weights; fp16 stores them in half precision and computes in it. HOOPICS
  measures both on the first picture and keeps the faster one when the results agree.
- The bicubic part is a fixed 5x5 convolution: DirectML has no bicubic resize, and ONNX Runtime would
  otherwise run that step on the CPU.
- On a test picture the result matched the author's own ONNX export within 1/255 per pixel.
- The build gives the same ZIP on any machine; it was rebuilt with two numpy versions and fresh
  downloads, and the release workflow refuses a build that differs from the hash HOOPICS pins.

## How they were chosen

On the author's laptop (GTX 1650 Ti, Iris Xe), against the Real-ESRGAN models of HOOPICS 0.1.x; the
numbers and the method are in [ROADMAP.md](ROADMAP.md), stage 2.

- Speed, 1178x661 to 4712x2644: 4.4 s on the GTX and 7.2 s on the Iris Xe. The Real-ESRGAN photo
  model took 14.6 s on the GTX in HOOPICS 0.1.x, and 22.8 s on the new engine.
- Photos: about as good as the Real-ESRGAN photo model on photos degraded on purpose, a little behind
  it on photos that were already of low quality. Both sometimes change the shape of small text.
- Anime and illustration: clean, but softer than the extra-sharp Real-ESRGAN anime model. Users who
  want that look can still download HOOPICS 0.1.x from the releases.
- waifu2x was left out because its training data was crawled from the web.

## Known limits

- Very small text can come out in a different shape. Use a larger original when the text matters.
- Tested only on the author's laptop. On any GPU HOOPICS checks every tile, recomputes a doubtful one
  on the CPU, and finishes the picture on the CPU when the GPU computes wrongly.
