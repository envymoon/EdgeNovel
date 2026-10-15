# Anime cover model

What the app's AI 封面 runs, and how to make it again. The built files are
hosted (see [Hosted](#hosted)). Until the app downloads them itself, the
engine and the model go into `%APPDATA%\com.novel\novel\image\`
by hand; see [Install](#install).

## What it is

| Part | What | Size |
|---|---|---|
| Engine | stable-diffusion.cpp `1b0ba10` (ggml `d25b121`) + `sdcpp-quantized-conv.patch`, built with Vulkan | `sd-cli.exe`, 82 MB, one file: the MSVC runtime is linked in |
| Model | Counterfeit V3.0 (anime SD 1.5), Hyper-SD 4-step LoRA merged in, VAE removed, Q5_0 | 695 MB (728,811,248 bytes) |
| Decoder | TAESD | `taesd.safetensors`, 9.8 MB (9,793,292 bytes) |

Generation runs at 512×768, 4 steps, TCD sampler, cfg 1, clip-skip 2, flash
attention, with tiled decoding (below). The arguments live in `draw_cover` in
`app/rust/src/api/image.rs`.

## Why the engine is patched

ggml quantizes in rows of 32-value blocks. Stock sd.cpp keeps every UNet
convolution kernel in F16, because a kernel's rows ([KW, KH, IC, OC]) are 3
values long, so a Q5 SD 1.5 is still 1.44 GB.

The patch:
- **Storage.** A quantizable 3×3 kernel is stored as the [KW·KH·IC, OC] matrix
  that `ggml_conv_2d` reshapes it to anyway. This only reinterprets the memory:
  the order matches the im2col columns.
- **Compute.** Such a convolution runs as im2col, then `mul_mat`.
- **What changed.** 4 files, +109/−17: the converter, `Conv2d` loading, and the
  conv compute.
- **Compatibility.** Old GGUFs and plain safetensors load and run unchanged.

The im2col columns are F32, not the F16 that `ggml_conv_2d` uses:
- The CPU backend only multiplies quantized weights by F32.
- GPUs without NVIDIA's coopmat2 would dequantize a copy of the kernel for F16.
  That makes an Iris Xe 10% slower, and phone GPUs are in the same position.
- The cost is about 100 MB more compute buffer at 512×768.

## Measurements

All at 512×768 with the model loaded, on one laptop: RTX 4060 Laptop,
Iris Xe and i9-13900H.

| | Q5, stock engine (1.44 GB) | Q5, patched (0.70 GB) |
|---|---|---|
| RTX 4060 | ~3.1 s | ~2.85 s |
| Iris Xe | ~12.2 s | ~10.5 s |
| CPU only | ~32 s | ~29 s |
| 4060 VRAM peak, above idle | ~2.2 GB | ~1.6 GB; 1.13 GB with tiled decoding |

Quality matches the 1.44 GB Q5: the same compositions, and faces compare
evenly at 1:1. Any difference from 25-step sampling comes from the 4-step
LoRA, not from quantization.

### Tiled decoding

TAESD needs 720 MB of scratch to decode 512×768 in one piece, which is more
than the whole model. The fix is full-width strips, each 37.5% of the height,
overlapping by half:

```
--vae-tiling --vae-relative-tile-size 1x0.375 --vae-tile-overlap 0.5
```

That gives 4 strips and 270 MB of scratch. Drawing already needs 287 MB, so
the peak is now set by drawing, not decoding.

| | Whole | Strips |
|---|---|---|
| Decode scratch | 720 MB | 270 MB |
| 4060 VRAM peak | ~1.57 GB | ~1.13 GB |
| Decode, RTX 4060 | 0.66 s | 0.46 s |
| Decode, Iris Xe | 0.8 s | 0.95 s |
| Decode, CPU | 3.6 s | 5.4 s |

- **Quality.** PSNR against the whole decode is 48–53 dB. Mean error is under
  1/255, and no seam is visible at 1:1. Portrait and landscape behave the same.
- **Why strips, not squares.**
  - The default 256 px squares score 44 dB and take 1.4 s on the Iris Xe.
  - 384 px squares are near-lossless but add 0.5 s there.
  - Strips re-decode the fewest pixels for the same scratch size.

## Remake

1. Download the sources:
   - https://huggingface.co/gsdf/Counterfeit-V3.0/resolve/main/Counterfeit-V3.0_fix_fp16.safetensors
   - https://huggingface.co/ByteDance/Hyper-SD/resolve/main/Hyper-SD15-4steps-lora.safetensors
   - https://huggingface.co/madebyollin/taesd/resolve/main/diffusion_pytorch_model.safetensors.
     Save it as `taesd.safetensors`.
2. Merge the LoRA and drop the VAE. This needs `numpy` and `safetensors`.
   ```
   python merge_lora.py Counterfeit-V3.0_fix_fp16.safetensors Hyper-SD15-4steps-lora.safetensors merged.safetensors f16
   python strip_vae.py merged.safetensors merged_novae.safetensors
   ```
3. Build the engine. You need VS 2022 Build Tools and the Vulkan SDK.
   ```
   git clone https://github.com/leejet/stable-diffusion.cpp sdcpp
   cd sdcpp && git checkout 1b0ba10 && git submodule update --init ggml
   git apply ..\sdcpp-quantized-conv.patch
   cd .. && build_engine.bat sdcpp C:\sdb
   ```
4. Convert:
   ```
   C:\sdb\bin\sd-cli.exe -M convert -m merged_novae.safetensors -o anime-cover-q5_0.gguf --type q5_0
   ```
   The log should report `97 conv kernels as matrices`.

## Hosted

| What | Where |
|---|---|
| Model and decoder | https://huggingface.co/ianhaimo/edgenovel-anime-cover (also through hf-mirror.com) |
| Engine, patch, licences | https://github.com/envymoon/EdgeNovel/releases/tag/image-engine-1, `sd-cli-windows-x64-vulkan.zip` |

The model repo carries the OpenRAIL-M text with its use restrictions, and says
what was changed: LoRA merged, VAE removed, Q5_0 with the patch. Both pages
list SHA-256 sums.

`build_engine.bat` links the C++ runtime in
(`CMAKE_MSVC_RUNTIME_LIBRARY=MultiThreaded`). An exe built by a newer MSVC
crashed against an older `msvcp140.dll` already on the machine. The exe still
imports `vulkan-1.dll`, which every GPU driver installs. On a machine with no
GPU driver at all it does not start, CPU included.

## Install

Put these three files into `%APPDATA%\com.novel\novel\image\`:
- `sd-cli.exe`
- the `.gguf`
- `taesd.safetensors`

The app finds them by name: `sd-cli.exe`, `taesd.safetensors`, and the first
`*.gguf`. AI 设置 then shows 生图模型 as installed, and that is where it is
deleted. The edit-book dialog offers AI 生成 only while all three are present.

## Prompts

Prompts are assembled in `image.rs` from fixed vocabulary. The reader picks a
person (少女 / 少年 / 无人物) and a setting (the 13 genres plus 插画); no model
writes tags. To redraw every pairing side by side before changing the
vocabulary, list every prompt the dialog can send with:

```
cargo test --lib all_cover_prompts -- --ignored --nocapture
```

## Licences

| Part | Licence |
|---|---|
| stable-diffusion.cpp | MIT |
| TAESD | MIT |
| Counterfeit V3.0 | CreativeML OpenRAIL-M |
| Hyper-SD | See its model card |

Read both model cards before hosting the merged model for anyone else. The
OpenRAIL-M use restrictions travel with derivatives.
