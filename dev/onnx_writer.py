"""Minimal ONNX writer for HOOPICS developer tools.

Writes the ONNX protobuf (proto3 wire format) directly, so the tools need only numpy: no onnx, torch or protobuf
package. It covers what our upscaling graphs use: plain nodes, initializers, int/float/string/ints attributes,
inputs and outputs with fixed or named (symbolic) dimensions, and model metadata.
"""
import struct

import numpy as np

FLOAT, INT64, FLOAT16 = 1, 7, 10
_ATTR_FLOAT, _ATTR_INT, _ATTR_STRING, _ATTR_INTS = 1, 2, 3, 7


def _varint(n):
    if n < 0:
        n += 1 << 64
    out = bytearray()
    while True:
        b = n & 0x7F
        n >>= 7
        if n:
            out.append(b | 0x80)
        else:
            out.append(b)
            return bytes(out)


def _field_varint(field, value):
    return _varint(field << 3) + _varint(int(value))


def _field_bytes(field, data):
    if isinstance(data, str):
        data = data.encode('utf-8')
    return _varint((field << 3) | 2) + _varint(len(data)) + data


def _field_float(field, value):
    return _varint((field << 3) | 5) + struct.pack('<f', float(value))


def attr_int(name, value):
    return _field_bytes(1, name) + _field_varint(20, _ATTR_INT) + _field_varint(3, value)


def attr_float(name, value):
    return _field_bytes(1, name) + _field_varint(20, _ATTR_FLOAT) + _field_float(2, value)


def attr_str(name, value):
    return _field_bytes(1, name) + _field_varint(20, _ATTR_STRING) + _field_bytes(4, value)


def attr_ints(name, values):
    return _field_bytes(1, name) + _field_varint(20, _ATTR_INTS) + b''.join(_field_varint(8, v) for v in values)


def _tensor(name, array, elem_type):
    data = b''.join(_field_varint(1, d) for d in array.shape)
    return data + _field_varint(2, elem_type) + _field_bytes(8, name) + _field_bytes(9, array.tobytes())


def _value_info(name, elem_type, shape):
    # A dimension is an int (dim_value) or a str (dim_param, a named symbolic size).
    dims = b''.join(
        _field_bytes(1, _field_bytes(2, d) if isinstance(d, str) else _field_varint(1, d)) for d in shape)
    tensor_type = _field_varint(1, elem_type) + _field_bytes(2, dims)
    return _field_bytes(1, name) + _field_bytes(2, _field_bytes(1, tensor_type))


class Graph:
    """Collects nodes and initializers. Weights are stored as float16 when fp16=True, else float32."""

    def __init__(self, fp16=False):
        self.fp16 = fp16
        self.nodes = []
        self.initializers = []
        self.parameters = 0
        self._count = 0

    def _name(self, prefix):
        self._count += 1
        return '%s_%d' % (prefix, self._count)

    def node(self, op, inputs, outputs=None, attrs=()):
        if outputs is None:
            outputs = [self._name(op.lower())]
        data = b''.join(_field_bytes(1, i) for i in inputs)
        data += b''.join(_field_bytes(2, o) for o in outputs)
        data += _field_bytes(3, self._name('node_' + op)) + _field_bytes(4, op)
        data += b''.join(_field_bytes(5, a) for a in attrs)
        self.nodes.append(data)
        return outputs[0]

    def weight(self, array):
        """A learned tensor, stored in the graph's weight precision."""
        array = np.ascontiguousarray(array, dtype=np.float16 if self.fp16 else np.float32)
        self.parameters += array.size
        return self._initializer(array, FLOAT16 if self.fp16 else FLOAT)

    def constant(self, array, elem_type):
        dtype = {FLOAT: np.float32, INT64: np.int64, FLOAT16: np.float16}[elem_type]
        return self._initializer(np.ascontiguousarray(array, dtype=dtype), elem_type)

    def _initializer(self, array, elem_type):
        name = self._name('w')
        self.initializers.append(_tensor(name, array, elem_type))
        return name

    def scalar(self, value):
        """A constant in the precision the graph computes in, for Mul/Add with activations."""
        return self.constant(np.array([value]), FLOAT16 if self.fp16 else FLOAT)

    def to_model(self, name, inputs, outputs, metadata=None, opset=17, producer='hoopics-dev'):
        """inputs/outputs: (name, elem_type, shape) tuples. metadata: dict of str -> str."""
        graph = b''.join(_field_bytes(1, n) for n in self.nodes) + _field_bytes(2, name)
        graph += b''.join(_field_bytes(5, t) for t in self.initializers)
        graph += b''.join(_field_bytes(11, _value_info(*i)) for i in inputs)
        graph += b''.join(_field_bytes(12, _value_info(*o)) for o in outputs)
        model = _field_varint(1, 8) + _field_bytes(2, producer)
        model += _field_bytes(7, graph)
        model += _field_bytes(8, _field_bytes(1, '') + _field_varint(2, opset))
        for key, value in (metadata or {}).items():
            model += _field_bytes(14, _field_bytes(1, key) + _field_bytes(2, value))
        return model
