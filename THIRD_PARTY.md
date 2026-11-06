# Third-party components

- RawNIND / NIND neural network models: Benoit Brummer (UCLouvain), GPL-3.0. https://github.com/trougnouf/rawnind_jddc and https://github.com/trougnouf/nind-denoise . Distribution and model cards: https://github.com/darktable-org/darktable-ai/releases/tag/release-5.6.0 . Archive SHA-256 values are pinned in `Scripts/prepare.py`.
- LibRaw 0.22.3: LibRaw LLC and contributors, LGPL-2.1 / CDDL dual license. Built from https://github.com/LibRaw/LibRaw/tree/0.22.3 . Distributed as part of this GPL application with corresponding source and build recipe.
- ONNX Runtime 1.24.3: Microsoft and contributors, MIT. https://github.com/microsoft/onnxruntime/tree/v1.24.3 . Acquired through CocoaPods.
- Sony FE 24–105mm F4 G OSS calibration: Lensfun contributors, CC-BY-SA-3.0. Extracted from https://github.com/lensfun/lensfun/blob/master/data/db/mil-sony.xml . Bundled as `Models/sony24105.json`. The data are not Sony-issued profiles. No calibration data are invented for other lenses.

Runtime algorithm reference: darktable's documented RawNIND preprocessing (Bayer packing, daylight white balance, gain matching and remosaicing). https://github.com/darktable-org/darktable/tree/release-5.6.2/src/common/ai
