"""Convert a NERVE checkpoint (.safetensors) to the ONNX files the HOOPICS engine opens.

NERVE (https://huggingface.co/Phips/NERVE, Philip Hofmann, Apache-2.0) gives HOOPICS 0.2 its models; Build-Models.ps1
runs this on the pinned checkpoints. Reads the safetensors file directly (a JSON header and raw tensors: no pickle,
no torch) and writes the network from nerve_arch.py as ONNX opset 17:

  5x5 stem -> 24 x (Conv-ReLU-Conv + x) -> + stem -> 3x3 conv to 3*scale^2 channels -> PixelShuffle -> + bicubic(x)

DirectML has no bicubic Resize, so ONNX Runtime would run that one node on the CPU. The bicubic part is written as
a fixed 5x5 convolution instead, one output channel per sub-pixel position, added before the PixelShuffle
(PyTorch's bicubic: a = -0.75, half-pixel centres, edge pixels repeated).

Usage: python -I nerve_to_onnx.py <model.safetensors> <out-prefix>
Writes <out-prefix>.fp32.onnx and <out-prefix>.fp16.onnx. Both take and return float32 NCHW RGB in [0, 1], with
named dimensions "height" and "width", like the files from dev/parity/ncnn_to_onnx.py.
"""
import argparse
import json
import os
import struct
import sys

import numpy as np

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), '..'))
import onnx_writer as ow  # noqa: E402

DTYPES = {'F32': '<f4', 'F16': '<f2'}


def read_safetensors(path):
    data = open(path, 'rb').read()
    size = struct.unpack_from('<Q', data)[0]
    header = json.loads(data[8:8 + size].decode('utf-8'))
    meta = json.loads(header.pop('__metadata__', {}).get('metadata', '{}'))
    tensors = {}
    for name, entry in header.items():
        if entry['dtype'] not in DTYPES:
            raise ValueError('%s: unsupported dtype %s' % (name, entry['dtype']))
        start, end = entry['data_offsets']
        array = np.frombuffer(data, DTYPES[entry['dtype']], (end - start) // np.dtype(DTYPES[entry['dtype']]).itemsize,
                              8 + size + start)
        tensors[name] = array.astype(np.float32).reshape(entry['shape'])
    return tensors, meta


def cubic(d, a=-0.75):
    d = abs(d)
    if d <= 1:
        return (a + 2) * d ** 3 - (a + 3) * d ** 2 + 1
    if d < 2:
        return a * d ** 3 - 5 * a * d ** 2 + 8 * a * d - 4 * a
    return 0.0


def bicubic_kernel(scale):
    """Weights (3*scale^2, 1, 5, 5) for a grouped convolution over the edge-padded input.

    Output pixel scale*i + p samples the input at i + (p + 0.5) / scale - 0.5, which needs inputs i-2 .. i+2."""
    taps = np.array([[cubic((p + 0.5) / scale - 0.5 - o) for o in range(-2, 3)] for p in range(scale)])
    kernel = np.zeros((3 * scale * scale, 1, 5, 5), np.float64)
    for c in range(3):
        for py in range(scale):
            for px in range(scale):
                kernel[c * scale * scale + py * scale + px, 0] = np.outer(taps[py], taps[px])
    return kernel


def conv(g, x, weight, pad, group=1, learned=True):
    k = weight.shape[2]
    attrs = [ow.attr_ints('kernel_shape', [k, k]), ow.attr_ints('pads', [pad] * 4)]
    if group > 1:
        attrs.append(ow.attr_int('group', group))
    w = g.weight(weight) if learned else g.constant(weight, ow.FLOAT16 if g.fp16 else ow.FLOAT)
    return g.node('Conv', [x, w], attrs=attrs)


def convert(t, scale, fp16):
    g = ow.Graph(fp16)
    x = g.node('Cast', ['input'], attrs=[ow.attr_int('to', ow.FLOAT16)]) if fp16 else 'input'
    feat = conv(g, x, t['stem.weight'], 2)
    out = feat
    n = 0
    while 'blocks.%d.conv1.weight' % n in t:
        inner = g.node('Relu', [conv(g, out, t['blocks.%d.conv1.weight' % n], 1)])
        out = g.node('Add', [out, conv(g, inner, t['blocks.%d.conv2.weight' % n], 1)])
        n += 1
    out = g.node('Add', [feat, out])
    out = conv(g, out, t['upsampler.0.weight'], 1)
    padded = g.node('Pad', [x, g.constant(np.array([0, 0, 2, 2, 0, 0, 2, 2]), ow.INT64)], attrs=[ow.attr_str('mode', 'edge')])
    out = g.node('Add', [out, conv(g, padded, bicubic_kernel(scale), 0, group=3, learned=False)])
    out = g.node('DepthToSpace', [out], attrs=[ow.attr_int('blocksize', scale), ow.attr_str('mode', 'CRD')])
    if fp16:
        g.node('Cast', [out], outputs=['output'], attrs=[ow.attr_int('to', ow.FLOAT)])
    else:
        g.node('Identity', [out], outputs=['output'])
    expected = 2 + 2 * n
    if len(t) != expected:
        raise ValueError('used %d of %d tensors; this is not a NERVE checkpoint' % (expected, len(t)))
    return g, n


def main():
    parser = argparse.ArgumentParser(description=__doc__.split('\n')[0])
    parser.add_argument('checkpoint')
    parser.add_argument('prefix')
    args = parser.parse_args()
    tensors, meta = read_safetensors(args.checkpoint)
    scale = int(meta.get('upscale', 0))
    if tensors['upsampler.0.weight'].shape[0] != 3 * scale * scale:
        raise ValueError('the upsampler does not match the scale %d in the checkpoint' % scale)
    stem = os.path.splitext(os.path.basename(args.checkpoint))[0]
    for precision in ('fp32', 'fp16'):
        g, blocks = convert(tensors, scale, precision == 'fp16')
        model = g.to_model(
            stem,
            inputs=[('input', ow.FLOAT, [1, 3, 'height', 'width'])],
            outputs=[('output', ow.FLOAT, [1, 3, 'out_height', 'out_width'])],
            metadata={'hoopics.scale': str(scale), 'hoopics.source': stem + ' (NERVE by Philip Hofmann, Apache-2.0)'})
        path = '%s.%s.onnx' % (args.prefix, precision)
        with open(path, 'wb') as f:
            f.write(model)
        print('%s\tscale=%d\tblocks=%d\tparameters=%d\tbytes=%d' % (path, scale, blocks, g.parameters, len(model)))


if __name__ == '__main__':
    main()
