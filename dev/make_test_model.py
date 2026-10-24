"""Write the tiny 4x model the tests run the engine with: a fixed 3x3 blur per colour, then nearest-neighbour 4x.

It has hand-set weights and nothing learned, so it is ours to publish. The blur needs one pixel of context, which
makes tiling testable: with any padding of 1 px or more, a tiled run must equal a single-tile run exactly.

Usage: python -I dev/make_test_model.py tests/fixtures
Writes blur-x4.fp32.onnx and blur-x4.fp16.onnx.
"""
import os
import sys

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import onnx_writer as ow  # noqa: E402


def build(fp16):
    g = ow.Graph(fp16)
    x = 'input'
    if fp16:
        x = g.node('Cast', [x], attrs=[ow.attr_int('to', ow.FLOAT16)])
    # Each output colour: half the pixel itself plus half the mean of its 3x3 neighbourhood, same colour only.
    weights = np.zeros((3, 3, 3, 3), np.float32)
    for c in range(3):
        weights[c, c] = 0.5 / 9
        weights[c, c, 1, 1] += 0.5
    y = g.node('Conv', [x, g.weight(weights), g.weight(np.zeros(3, np.float32))],
               attrs=[ow.attr_ints('kernel_shape', [3, 3]), ow.attr_ints('pads', [1, 1, 1, 1])])
    scales = g.constant(np.array([1, 1, 4, 4]), ow.FLOAT)
    y = g.node('Resize', [y, '', scales], attrs=[
        ow.attr_str('mode', 'nearest'), ow.attr_str('coordinate_transformation_mode', 'asymmetric'),
        ow.attr_str('nearest_mode', 'floor')])
    if fp16:
        g.node('Cast', [y], outputs=['output'], attrs=[ow.attr_int('to', ow.FLOAT)])
    else:
        g.node('Identity', [y], outputs=['output'])
    return g.to_model(
        'blur-x4',
        inputs=[('input', ow.FLOAT, [1, 3, 'height', 'width'])],
        outputs=[('output', ow.FLOAT, [1, 3, 'out_height', 'out_width'])],
        metadata={'hoopics.scale': '4'},
        producer='hoopics-tests')


def main():
    out = sys.argv[1]
    os.makedirs(out, exist_ok=True)
    for precision in ('fp32', 'fp16'):
        path = os.path.join(out, 'blur-x4.%s.onnx' % precision)
        with open(path, 'wb') as f:
            f.write(build(precision == 'fp16'))
        print(path, os.path.getsize(path))


if __name__ == '__main__':
    main()
