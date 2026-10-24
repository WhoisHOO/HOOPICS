"""Convert a Real-ESRGAN ncnn model (.param + .bin) to ONNX, for comparing the old and new engines.

DEVELOPMENT ONLY. HOOPICS 0.2 does not ship Real-ESRGAN models; these files are the quality and speed baseline
while our own engine and models are built (see docs/ROADMAP.md). Never commit or publish the converted files.

Reads the ncnn graph text and the raw weights directly (no pickle, no torch) and writes the same math as ONNX
opset 17. It supports the layers the Real-ESRGAN ncnn models use: Input, Split, Convolution (+ ReLU/LeakyReLU),
PReLU, Concat, Eltwise (SUM with coefficients), BinaryOp, Interp (nearest) and PixelShuffle.

Usage: python -I ncnn_to_onnx.py <model.param> <out-prefix> [--scale 4]
Writes <out-prefix>.fp32.onnx and <out-prefix>.fp16.onnx, which HOOPICS looks for in engine/models. Both take and
return float32 NCHW RGB in [0, 1], with named dimensions "height" and "width" so the engine can fix the tile size
when it opens the model.
Converting the three models HOOPICS 0.1.1 installed:
  python -I dev/parity/ncnn_to_onnx.py engine/realesrgan-ncnn-vulkan-20220424/models/realesr-animevideov3-x4.param engine/models/realesr-animevideov3-x4
  (and the same for realesrgan-x4plus-anime and realesrgan-x4plus)
"""
import argparse
import os
import struct
import sys

import numpy as np

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), '..'))
import onnx_writer as ow  # noqa: E402

FP16_FLAG = 0x01306B47


def parse_param(path):
    lines = [l.split() for l in open(path, encoding='ascii').read().splitlines()]
    if lines[0] != ['7767517']:
        raise ValueError('not an ncnn .param file: ' + path)
    layers = []
    for parts in lines[2:]:
        if not parts:
            continue
        kind, name, n_in, n_out = parts[0], parts[1], int(parts[2]), int(parts[3])
        inputs = parts[4:4 + n_in]
        outputs = parts[4 + n_in:4 + n_in + n_out]
        params = {}
        for item in parts[4 + n_in + n_out:]:
            key, value = item.split('=', 1)
            key = int(key)
            if key <= -23300:
                # Array parameter: "-233xx=count,v1,v2,..." holds parameter id xx.
                values = value.split(',')
                params[-(key + 23300)] = [float(v) for v in values[1:1 + int(values[0])]]
            else:
                params[key] = float(value) if ('.' in value or 'e' in value) else int(value)
        layers.append((kind, name, inputs, outputs, params))
    return layers


class Weights:
    def __init__(self, path):
        self.data = open(path, 'rb').read()
        self.pos = 0

    def flagged(self, count):
        """Weights stored with a 4-byte type flag: fp16 (padded to 4 bytes) or raw fp32."""
        flag = struct.unpack_from('<I', self.data, self.pos)[0]
        self.pos += 4
        if flag == FP16_FLAG:
            values = np.frombuffer(self.data, '<f2', count, self.pos).astype(np.float32)
            self.pos += (count * 2 + 3) // 4 * 4
        elif flag == 0:
            values = np.frombuffer(self.data, '<f4', count, self.pos).copy()
            self.pos += count * 4
        else:
            raise ValueError('unsupported weight flag 0x%08X at byte %d' % (flag, self.pos - 4))
        return values

    def raw(self, count):
        values = np.frombuffer(self.data, '<f4', count, self.pos).copy()
        self.pos += count * 4
        return values


def convert(layers, weights, fp16):
    g = ow.Graph(fp16)
    blobs = {}
    for kind, name, inputs, outputs, p in layers:
        src = [blobs[i] for i in inputs]
        if kind == 'Input':
            x = 'input'
            if fp16:
                x = g.node('Cast', ['input'], attrs=[ow.attr_int('to', ow.FLOAT16)])
            out = x
        elif kind == 'Split':
            for o in outputs:
                blobs[o] = src[0]
            continue
        elif kind == 'Convolution':
            cout, k, bias, size = p[0], p[1], p.get(5, 0), p[6]
            if p.get(11, k) != k or p.get(2, 1) != 1 or p.get(3, 1) != 1 or p.get(4, 0) != k // 2:
                raise ValueError('%s: only square, stride-1, same-padded convolutions are supported' % name)
            w = weights.flagged(size).reshape(cout, size // (cout * k * k), k, k)
            b = weights.raw(cout) if bias else np.zeros(cout, np.float32)
            out = g.node('Conv', [src[0], g.weight(w), g.weight(b)], attrs=[
                ow.attr_ints('kernel_shape', [k, k]), ow.attr_ints('pads', [k // 2] * 4)])
            activation = p.get(9, 0)
            if activation == 1:
                out = g.node('Relu', [out])
            elif activation == 2:
                out = g.node('LeakyRelu', [out], attrs=[ow.attr_float('alpha', p[10][0])])
            elif activation != 0:
                raise ValueError('%s: unsupported activation %d' % (name, activation))
        elif kind == 'PReLU':
            slopes = weights.raw(p[0])
            out = g.node('PRelu', [src[0], g.weight(slopes.reshape(-1, 1, 1))])
        elif kind == 'Concat':
            if p.get(0, 0) != 0:
                raise ValueError('%s: only channel concatenation is supported' % name)
            out = g.node('Concat', src, attrs=[ow.attr_int('axis', 1)])
        elif kind == 'Eltwise':
            if p.get(0) != 1:
                raise ValueError('%s: only Eltwise SUM is supported' % name)
            coeffs = p.get(1, [1.0] * len(src))
            terms = [s if c == 1.0 else g.node('Mul', [s, g.scalar(c)]) for s, c in zip(src, coeffs)]
            out = terms[0]
            for t in terms[1:]:
                out = g.node('Add', [out, t])
        elif kind == 'BinaryOp':
            if p.get(0, 0) != 0 or p.get(1, 0) != 0:
                raise ValueError('%s: only two-input BinaryOp ADD is supported' % name)
            out = g.node('Add', src)
        elif kind == 'Interp':
            if p.get(0) != 1:
                raise ValueError('%s: only nearest Interp is supported' % name)
            scales = g.constant(np.array([1, 1, p[1], p[2]]), ow.FLOAT)
            out = g.node('Resize', [src[0], '', scales], attrs=[
                ow.attr_str('mode', 'nearest'), ow.attr_str('coordinate_transformation_mode', 'asymmetric'),
                ow.attr_str('nearest_mode', 'floor')])
        elif kind == 'PixelShuffle':
            if p.get(1, 0) != 0:
                raise ValueError('%s: only PyTorch-style PixelShuffle is supported' % name)
            out = g.node('DepthToSpace', [src[0]], attrs=[ow.attr_int('blocksize', p[0]), ow.attr_str('mode', 'CRD')])
        else:
            raise ValueError('%s: unsupported layer type %s' % (name, kind))
        blobs[outputs[0]] = out
    last = blobs[layers[-1][3][0]]
    if fp16:
        g.node('Cast', [last], outputs=['output'], attrs=[ow.attr_int('to', ow.FLOAT)])
    else:
        g.node('Identity', [last], outputs=['output'])
    if weights.pos != len(weights.data):
        raise ValueError('read %d of %d weight bytes; the graph and weights do not match' % (weights.pos, len(weights.data)))
    return g


def main():
    parser = argparse.ArgumentParser(description=__doc__.split('\n')[0])
    parser.add_argument('param')
    parser.add_argument('prefix')
    parser.add_argument('--scale', type=int, default=4)
    args = parser.parse_args()
    layers = parse_param(args.param)
    stem = os.path.splitext(os.path.basename(args.param))[0]
    for precision in ('fp32', 'fp16'):
        g = convert(layers, Weights(args.param[:-len('.param')] + '.bin'), precision == 'fp16')
        model = g.to_model(
            stem,
            inputs=[('input', ow.FLOAT, [1, 3, 'height', 'width'])],
            outputs=[('output', ow.FLOAT, [1, 3, 'out_height', 'out_width'])],
            metadata={'hoopics.scale': str(args.scale), 'hoopics.source': stem + ' (ncnn, development baseline only)'})
        path = '%s.%s.onnx' % (args.prefix, precision)
        with open(path, 'wb') as f:
            f.write(model)
        print('%s\tparameters=%d\tbytes=%d' % (path, g.parameters, len(model)))


if __name__ == '__main__':
    main()
